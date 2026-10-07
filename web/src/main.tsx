import { render } from 'preact';
import { App } from './app.tsx';
import './styles/all.ts';
import './styles/motion.css';

render(<App />, document.getElementById('app')!);
