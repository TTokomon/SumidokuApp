import { useEffect } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { qk } from '../api/hooks';
import { useNavigate } from 'react-router-dom';
import { Button } from '../components/Button';

type DesktopWindow = Window & { __sumidokuDesktop?: boolean; __sumidokuRouterReady?: boolean; webkit?: { messageHandlers?: { desktop?: { postMessage: (body: Record<string, string>) => Promise<unknown> } } } };
export function desktopHost() {
	if (typeof window === 'undefined') return undefined;
	const host = window as DesktopWindow;
	return host.__sumidokuDesktop ? host.webkit?.messageHandlers?.desktop : undefined;
}
export function validDesktopRoute(value: unknown): value is string {
	return typeof value === 'string' && value.length <= 2048 && value.startsWith('/') && !value.startsWith('//') && !value.includes('\\');
}
export function DesktopNavigationBridge() {
	const navigate = useNavigate();
	const client = useQueryClient();
	useEffect(() => {
		if (!desktopHost()) return;
		const listener = (event: Event) => { const route = (event as CustomEvent<unknown>).detail; if (validDesktopRoute(route)) navigate(route); };
		(window as DesktopWindow).__sumidokuRouterReady = true;
		window.addEventListener('sumidoku:navigate', listener);
		const sourcesChanged = () => { void client.invalidateQueries({ queryKey: qk.sourceRepos }); };
		window.addEventListener('sumidoku:source-lists', sourcesChanged);
		return () => { (window as DesktopWindow).__sumidokuRouterReady = false; window.removeEventListener('sumidoku:navigate', listener); window.removeEventListener('sumidoku:source-lists', sourcesChanged); };
	}, [navigate, client]);
	return null;
}
export function DesktopUpdatesSection() {
	if (!desktopHost()) return null;
	return <section className="card settings-section" aria-label="Application Updates">
		<h2>Application Updates</h2>
		<p>Check for a new version of Sumidoku Desktop and view release notes. Application updates are separate from manga source updates.</p>
		<Button onClick={() => void desktopHost()?.postMessage({ action: 'checkUpdates' })}>Check Now…</Button>
	</section>;
}
