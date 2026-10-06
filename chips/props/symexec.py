"""Symbolic execution of plain integer Python with z3.

    m = Machine()
    ns, y = m.call(flow_governor.step, [m.input("s", 64), m.input("x", 96), params])

`call` reads the SOURCE of the function (inspect + ast) and executes it on z3 terms instead of numbers, so the
result is not a second description of the function: it is the function itself, as a formula over its inputs.
Functions it calls are executed the same way (here `_satsub`, `kernel_model.pack_output`, `pack_fields`).

What is supported is what straight-line integer code needs, and nothing else; any other construct raises
SymError, so a function this machine does not fully understand cannot be mis-read silently:

  statements    assignment (also chained and to tuples), augmented assignment, if / elif / else, for over a
                concrete sequence, assert, raise, return as the last statement, pass, a docstring
  expressions   integer and boolean constants, names, attribute and item lookups on concrete objects, a table
                (list or tuple) indexed by a symbolic integer, tuples, lists, dict displays,
                + - * & | ^ << >>, unary - and not, comparisons (chained too), and / or, x if c else y,
                min, max, calls of Python functions whose source is available, dict.get

How Python's semantics are kept:

  * Integers. Python integers are unbounded; a z3 bit-vector is not. Every integer term is WIDE bits wide and
    carries a bound `bits` with |value| < 2**bits, computed from the operation that produced it. An operation
    whose result could reach 2**(WIDE-2) raises. So no term ever wraps, and bit-vector arithmetic (signed
    comparisons, arithmetic right shift, two's complement & | ^) is exactly Python's.
  * Booleans. `bool` is a subclass of `int`: a boolean used in arithmetic is 0 or 1, an integer used as a
    condition is true when it is not 0, and `a and b` / `a or b` return one of their operands.
  * Control flow. A condition that is a plain Python value is simply followed. A symbolic one runs both
    branches and merges every variable with an if-then-else term; a variable assigned in only one branch is
    unusable afterwards. Expressions are evaluated under the condition that guards them (`a and b`, `b if a
    else c`), so a check inside `b` is only required where Python would evaluate `b`.
  * Things that can go wrong. `assert c` records the obligation "c holds whenever this line is reached";
    `raise` records "this line is never reached"; a table lookup records "the index is in range". `call`
    returns the value; `obligations` then holds everything that must be PROVEN for the formula to be the
    function (otherwise Python would have raised where the formula returns something).
"""
from __future__ import annotations

import ast
import inspect
import textwrap
from typing import Any, Callable, Dict, List, Optional, Sequence

import z3

WIDE = 160


class SymError(Exception):
    """The code uses something this machine does not model."""


class Int:
    """A symbolic integer: a WIDE-bit term and a bound on its magnitude (|value| < 2**bits)."""
    __slots__ = ("term", "bits")

    def __init__(self, term, bits: int):
        if bits > WIDE - 2:
            raise SymError(f"an integer of up to {bits} bits does not fit the {WIDE}-bit terms")
        self.term, self.bits = term, bits


class _Undefined:
    def __repr__(self):
        return "<assigned in only one branch>"


UNDEFINED = _Undefined()


def is_sym(v) -> bool:
    return isinstance(v, Int) or isinstance(v, z3.BoolRef)


def is_boolean(v) -> bool:
    return isinstance(v, bool) or isinstance(v, z3.BoolRef)


def is_integer(v) -> bool:
    return isinstance(v, Int) or (isinstance(v, int) and not isinstance(v, bool))


def as_bool(v):
    """Truth value, as a z3 Bool."""
    if isinstance(v, z3.BoolRef):
        return v
    if isinstance(v, Int):
        return v.term != 0
    if isinstance(v, (bool, int)):
        return z3.BoolVal(bool(v))
    raise SymError(f"no truth value for {type(v).__name__}")


def as_int(v) -> Int:
    """Integer value, as a WIDE-bit term (a boolean is 0 or 1, as in Python)."""
    if isinstance(v, Int):
        return v
    if isinstance(v, z3.BoolRef):
        return Int(z3.If(v, z3.BitVecVal(1, WIDE), z3.BitVecVal(0, WIDE)), 1)
    if isinstance(v, (bool, int)):
        return Int(z3.BitVecVal(int(v), WIDE), int(v).bit_length() if v >= 0 else (-int(v) - 1).bit_length() + 1)
    raise SymError(f"{type(v).__name__} is not an integer")


def conj(conds: Sequence) -> Any:
    conds = [c for c in conds if not z3.is_true(c)]
    return z3.BoolVal(True) if not conds else (conds[0] if len(conds) == 1 else z3.And(*conds))


class Machine:
    def __init__(self):
        self.obligations: List[tuple] = []      # (what, z3 Bool that must be valid)
        self.path: List[Any] = []               # conditions under which the current line is reached
        self.inputs: Dict[str, Any] = {}

    def input(self, name: str, width: int) -> Int:
        """A free input of `width` bits: an unsigned integer below 2**width."""
        v = z3.BitVec(name, width)
        self.inputs[name] = v
        return Int(z3.ZeroExt(WIDE - width, v), width)

    # ------------------------------------------------------------------ obligations
    def oblige(self, what: str, cond) -> None:
        self.obligations.append((what, z3.Implies(conj(self.path), cond) if self.path else cond))

    # ------------------------------------------------------------------ functions
    def call(self, fn: Callable, args: Sequence, kwargs: Optional[dict] = None):
        src = textwrap.dedent(inspect.getsource(fn))
        node = ast.parse(src).body[0]
        if not isinstance(node, ast.FunctionDef):
            raise SymError(f"{fn!r} is not a plain function")
        a = node.args
        if a.vararg or a.kwarg or a.kwonlyargs or a.posonlyargs:
            raise SymError("only plain positional parameters are modelled")
        names = [p.arg for p in a.args]
        defaults = dict(zip(names[len(names) - len(fn.__defaults__ or ()):], fn.__defaults__ or ()))
        env = dict(defaults)
        env.update(zip(names, args))
        env.update(kwargs or {})
        missing = [n for n in names if n not in env]
        if missing or len(args) > len(names):
            raise SymError(f"{fn.__name__}: bad arguments")
        frame = _Frame(self, fn, env)
        body = node.body
        if not body or not isinstance(body[-1], ast.Return):
            raise SymError(f"{fn.__name__}: the function must end in a return statement")
        frame.block(body[:-1])
        return frame.expr(body[-1].value) if body[-1].value is not None else None

    # ------------------------------------------------------------------ operations
    def binop(self, op: ast.operator, a, b):
        if type(op) not in _CONCRETE:
            raise SymError(f"operator {type(op).__name__} is not modelled")
        if not (is_sym(a) or is_sym(b)):
            return _CONCRETE[type(op)](a, b)
        x, y = as_int(a), as_int(b)
        t = type(op)
        if t is ast.Add:
            return Int(x.term + y.term, max(x.bits, y.bits) + 1)
        if t is ast.Sub:
            return Int(x.term - y.term, max(x.bits, y.bits) + 1)
        if t is ast.Mult:
            return Int(x.term * y.term, x.bits + y.bits)
        # two's complement operands with |v| < 2**n are (n+1)-bit values, and so is any bitwise result of them:
        # it lies in [-2**n, 2**n), hence the one extra bit in the bound
        if t is ast.BitOr:
            return Int(x.term | y.term, max(x.bits, y.bits) + 1)
        if t is ast.BitXor:
            return Int(x.term ^ y.term, max(x.bits, y.bits) + 1)
        if t is ast.BitAnd:
            # with a non-negative constant mask the result lies in [0, mask] whatever the other operand is
            for c in (a, b):
                if not is_sym(c) and int(c) >= 0:
                    return Int(x.term & y.term, int(c).bit_length())
            return Int(x.term & y.term, max(x.bits, y.bits) + 1)
        if t is ast.LShift:
            if is_sym(b):
                raise SymError("a left shift by a symbolic amount is not modelled")
            if int(b) < 0:
                raise SymError("negative shift count")
            return Int(x.term << int(b), x.bits + int(b))
        if t is ast.RShift:
            if not is_sym(b):
                if int(b) < 0:
                    raise SymError("negative shift count")
            else:
                self.oblige("a shift count is not negative", y.term >= 0)
            return Int(x.term >> y.term, x.bits)            # arithmetic shift = Python's floor shift
        raise SymError(f"operator {t.__name__} is not modelled")

    def compare(self, op: ast.cmpop, a, b):
        if type(op) not in _CONCRETE:
            raise SymError(f"comparison {type(op).__name__} is not modelled")
        if not (is_sym(a) or is_sym(b)):
            return _CONCRETE[type(op)](a, b)
        t = type(op)
        if is_boolean(a) and is_boolean(b) and t in (ast.Eq, ast.NotEq):
            e = as_bool(a) == as_bool(b)
            return e if t is ast.Eq else z3.Not(e)
        x, y = as_int(a).term, as_int(b).term
        if t is ast.Eq:
            return x == y
        if t is ast.NotEq:
            return x != y
        if t is ast.Lt:
            return x < y                                     # signed, as the operands are signed integers
        if t is ast.LtE:
            return x <= y
        if t is ast.Gt:
            return x > y
        if t is ast.GtE:
            return x >= y
        raise SymError(f"comparison {t.__name__} is not modelled")

    def select(self, cond, a, b):
        """`a` where cond holds, `b` elsewhere (cond is a z3 Bool)."""
        if a is b:
            return a
        if not (is_sym(a) or is_sym(b)) and type(a) is type(b) and not isinstance(a, (tuple, list, dict)) and a == b:
            return a
        if isinstance(a, tuple) and isinstance(b, tuple) and len(a) == len(b):
            return tuple(self.select(cond, p, q) for p, q in zip(a, b))
        if is_boolean(a) and is_boolean(b):
            return z3.If(cond, as_bool(a), as_bool(b))
        if is_integer(a) and is_integer(b):
            x, y = as_int(a), as_int(b)
            return Int(z3.If(cond, x.term, y.term), max(x.bits, y.bits))
        raise SymError(f"cannot merge a {type(a).__name__} with a {type(b).__name__}")

    def lookup(self, table: Sequence, index: Int):
        self.oblige("a table index is in range", z3.And(index.term >= 0, index.term < len(table)))
        out = table[-1]
        for i in range(len(table) - 2, -1, -1):
            out = self.select(index.term == i, table[i], out)
        return out

    def minmax(self, which: str, args: Sequence):
        if not any(is_sym(v) for v in args):
            return (min if which == "min" else max)(*args)
        out = args[0]
        for v in args[1:]:
            x, y = as_int(v), as_int(out)
            take = (x.term < y.term) if which == "min" else (x.term > y.term)      # Python keeps the first on a tie
            out = self.select(take, v, out)
        return out


_CONCRETE = {
    ast.Add: lambda a, b: a + b, ast.Sub: lambda a, b: a - b, ast.Mult: lambda a, b: a * b,
    ast.BitAnd: lambda a, b: a & b, ast.BitOr: lambda a, b: a | b, ast.BitXor: lambda a, b: a ^ b,
    ast.LShift: lambda a, b: a << b, ast.RShift: lambda a, b: a >> b,
    ast.Eq: lambda a, b: a == b, ast.NotEq: lambda a, b: a != b, ast.Lt: lambda a, b: a < b,
    ast.LtE: lambda a, b: a <= b, ast.Gt: lambda a, b: a > b, ast.GtE: lambda a, b: a >= b,
}
_DIRECT = (len, range, int, bool, isinstance, tuple, list, dict)      # safe on concrete arguments only


class _Frame:
    """One activation of one function."""

    def __init__(self, machine: Machine, fn: Callable, env: dict):
        self.m, self.fn, self.env = machine, fn, env
        self.dead = False                 # set by a raise: the rest of this branch is never executed

    # ------------------------------------------------------------------ statements
    def block(self, stmts: Sequence[ast.stmt]) -> None:
        for s in stmts:
            if self.dead:
                return
            self.stmt(s)

    def stmt(self, s: ast.stmt) -> None:
        m = self.m
        if isinstance(s, ast.Expr):
            if not isinstance(s.value, ast.Constant):
                self.expr(s.value)
        elif isinstance(s, ast.Pass):
            pass
        elif isinstance(s, ast.Assign):
            v = self.expr(s.value)
            for t in s.targets:
                self.assign(t, v)
        elif isinstance(s, ast.AnnAssign) and s.value is not None:
            self.assign(s.target, self.expr(s.value))
        elif isinstance(s, ast.AugAssign):
            if not isinstance(s.target, ast.Name):
                raise SymError("augmented assignment to something that is not a name")
            self.env[s.target.id] = m.binop(s.op, self.load(s.target.id), self.expr(s.value))
        elif isinstance(s, ast.If):
            c = self.expr(s.test)
            if not is_sym(c):
                self.block(s.body if c else s.orelse)
                return
            cb = as_bool(c)
            branches = []
            for cond, body in ((cb, s.body), (z3.Not(cb), s.orelse)):
                f = _Frame(m, self.fn, dict(self.env))
                m.path.append(cond)
                f.block(body)
                m.path.pop()
                branches.append(f)
            t, e = branches
            if t.dead and e.dead:
                self.dead = True
            elif t.dead or e.dead:
                self.env = (e if t.dead else t).env        # the other branch is proven unreachable
            else:
                for k in set(t.env) | set(e.env):
                    if k in t.env and k in e.env:
                        try:
                            self.env[k] = m.select(cb, t.env[k], e.env[k])
                        except SymError:
                            self.env[k] = UNDEFINED
                    else:
                        self.env[k] = UNDEFINED
        elif isinstance(s, ast.For):
            it = self.expr(s.iter)
            if is_sym(it) or s.orelse:
                raise SymError("only loops over a concrete sequence are modelled")
            for item in it:
                self.assign(s.target, item)
                self.block(s.body)
                if self.dead:
                    return
        elif isinstance(s, ast.Assert):
            c = self.expr(s.test)
            if is_sym(c):
                m.oblige(f"{self.fn.__name__}: assert {ast.unparse(s.test)}", as_bool(c))
            elif not c:
                m.oblige(f"{self.fn.__name__}: assert {ast.unparse(s.test)} (false whenever reached)", z3.BoolVal(False))
        elif isinstance(s, ast.Raise):
            m.oblige(f"{self.fn.__name__}: line {s.lineno} (raise) is never reached", z3.BoolVal(False))
            self.dead = True
        else:
            raise SymError(f"statement {type(s).__name__} is not modelled ({self.fn.__name__}, line {s.lineno})")

    def assign(self, target: ast.expr, v) -> None:
        if isinstance(target, ast.Name):
            self.env[target.id] = v
        elif isinstance(target, (ast.Tuple, ast.List)):
            if not isinstance(v, (tuple, list)) or len(v) != len(target.elts):
                raise SymError("unpacking needs a concrete tuple of the same length")
            for t, x in zip(target.elts, v):
                self.assign(t, x)
        else:
            raise SymError(f"assignment to {type(target).__name__} is not modelled")

    def load(self, name: str):
        if name in self.env:
            v = self.env[name]
            if v is UNDEFINED:
                raise SymError(f"{name} is read after being assigned in only one branch")
            return v
        g = self.fn.__globals__
        if name in g:
            return g[name]
        b = g.get("__builtins__")
        b = b if isinstance(b, dict) else vars(b)
        if name in b:
            return b[name]
        raise SymError(f"unknown name {name}")

    # ------------------------------------------------------------------ expressions
    def under(self, cond, node: ast.expr):
        """Evaluate `node` as reached only where cond holds."""
        self.m.path.append(cond)
        try:
            return self.expr(node)
        finally:
            self.m.path.pop()

    def expr(self, e: ast.expr):
        m = self.m
        if isinstance(e, ast.Constant):
            if not isinstance(e.value, (int, bool, str)) and e.value is not None:
                raise SymError(f"constant {e.value!r} is not modelled")
            return e.value
        if isinstance(e, ast.Name):
            return self.load(e.id)
        if isinstance(e, ast.Attribute):
            base = self.expr(e.value)
            if is_sym(base):
                raise SymError("attribute of a symbolic value")
            return getattr(base, e.attr)
        if isinstance(e, ast.Tuple):
            return tuple(self.expr(x) for x in e.elts)
        if isinstance(e, ast.List):
            return [self.expr(x) for x in e.elts]
        if isinstance(e, ast.Dict):
            keys = [self.expr(k) for k in e.keys]
            if any(is_sym(k) for k in keys):
                raise SymError("symbolic dict key")
            return dict(zip(keys, [self.expr(v) for v in e.values]))
        if isinstance(e, ast.Subscript):
            base, idx = self.expr(e.value), self.expr(e.slice)
            if is_sym(base):
                raise SymError("subscript of a symbolic value")
            if not is_sym(idx):
                return base[idx]
            if not isinstance(base, (list, tuple)) or not base:
                raise SymError("a symbolic index needs a non-empty list or tuple")
            return m.lookup(base, as_int(idx))
        if isinstance(e, ast.BinOp):
            return m.binop(e.op, self.expr(e.left), self.expr(e.right))
        if isinstance(e, ast.UnaryOp):
            v = self.expr(e.operand)
            if isinstance(e.op, ast.Not):
                return z3.Not(as_bool(v)) if is_sym(v) else (not v)
            if isinstance(e.op, ast.USub):
                if not is_sym(v):
                    return -v
                x = as_int(v)
                return Int(-x.term, x.bits + 1)
            raise SymError(f"unary {type(e.op).__name__} is not modelled")
        if isinstance(e, ast.BoolOp):
            # `a and b` is b where a is true, else a; `a or b` is a where a is true, else b
            is_and = isinstance(e.op, ast.And)
            out = self.expr(e.values[0])
            guards = 0
            try:
                for nxt in e.values[1:]:
                    if not is_sym(out):
                        if bool(out) != is_and:
                            return out                       # decided: Python evaluates nothing further
                        out = self.expr(nxt)
                        continue
                    c = as_bool(out)
                    m.path.append(c if is_and else z3.Not(c))
                    guards += 1
                    rhs = self.expr(nxt)
                    out = m.select(c, rhs, out) if is_and else m.select(c, out, rhs)
                return out
            finally:
                del m.path[len(m.path) - guards:]
        if isinstance(e, ast.Compare):
            left = self.expr(e.left)
            parts = []
            for op, right_node in zip(e.ops, e.comparators):
                right = self.expr(right_node)
                parts.append(m.compare(op, left, right))
                left = right
            if len(parts) == 1:
                return parts[0]
            if not any(is_sym(p) for p in parts):
                return all(parts)
            return conj([as_bool(p) for p in parts])
        if isinstance(e, ast.IfExp):
            c = self.expr(e.test)
            if not is_sym(c):
                return self.expr(e.body if c else e.orelse)
            cb = as_bool(c)
            return m.select(cb, self.under(cb, e.body), self.under(z3.Not(cb), e.orelse))
        if isinstance(e, ast.Call):
            fn = self.expr(e.func)
            args = [self.expr(a) for a in e.args]
            kwargs = {k.arg: self.expr(k.value) for k in e.keywords}
            if any(k is None for k in kwargs):
                raise SymError("** arguments are not modelled")
            if fn is min or fn is max:
                if kwargs or len(args) < 2:
                    raise SymError("min / max of two or more positional arguments only")
                return m.minmax(fn.__name__, args)
            if inspect.isfunction(fn):
                return m.call(fn, args, kwargs)
            recv = getattr(fn, "__self__", None)
            if isinstance(recv, dict) and getattr(fn, "__name__", "") == "get" and not is_sym(args[0]):
                return fn(*args)                             # dict.get(key, default): the value is not inspected
            if fn in _DIRECT and not any(is_sym(a) for a in args) and not kwargs:
                return fn(*args)
            raise SymError(f"call of {getattr(fn, '__name__', fn)!r} is not modelled")
        raise SymError(f"expression {type(e).__name__} is not modelled ({self.fn.__name__}, line {e.lineno})")
