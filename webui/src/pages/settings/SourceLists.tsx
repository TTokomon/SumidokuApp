import { useState } from 'react';
import { Button } from '../../components';
import ReposPanel from '../browse/ReposPanel';
import { AddRepoModal } from '../browse/AddRepoModal';

export function SourceLists() {
	const [adding, setAdding] = useState(false);
	return <section aria-label="Source Lists">
		<h2>Source Lists</h2>
		<p className="muted">Manage your subscribed Aidoku-compatible source lists here. Built-in connections do not need a source list. Installed packages and repository subscriptions are separate.</p>
		<Button variant="primary" onClick={() => setAdding(true)}>Add Source List</Button>
		<ReposPanel />
		<AddRepoModal open={adding} onClose={() => setAdding(false)} />
	</section>;
}
