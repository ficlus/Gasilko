import { dictionary } from '../../lib/i18n';
export default function Loading() { return <main role="status"><p lang="sl">{dictionary('sl').loading}</p><p lang="de">{dictionary('de').loading}</p></main>; }
