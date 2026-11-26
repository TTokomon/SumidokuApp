import { createContext, useContext, useRef, useState } from 'react';
import type { Dispatch, ReactNode, RefObject, SetStateAction } from 'react';
import type { AidokuImportResponse } from '../../api/types';

export type AidokuImportStep = 1 | 2 | 3;

type Draft = { file: File; preview: AidokuImportResponse; current: boolean } | null;
interface Session {
	aib: Draft; setAib: Dispatch<SetStateAction<Draft>>;
	result: AidokuImportResponse | null; setResult: Dispatch<SetStateAction<AidokuImportResponse | null>>;
	paused: boolean; setPaused: Dispatch<SetStateAction<boolean>>;
	acceptSkips: boolean; setAcceptSkips: Dispatch<SetStateAction<boolean>>;
	step: AidokuImportStep; setStep: Dispatch<SetStateAction<AidokuImportStep>>;
	selected: string[]; setSelected: Dispatch<SetStateAction<string[]>>;
	seenDefaults: RefObject<Set<string>>;
}
const Context = createContext<Session | null>(null);

/** Memory only; survives page navigation and is discarded when the app layout/session unmounts. */
export function AidokuImportSessionProvider({ children }: { children: ReactNode }) {
	const [aib, setAib] = useState<Draft>(null);
	const [result, setResult] = useState<AidokuImportResponse | null>(null);
	const [paused, setPaused] = useState(false);
	const [acceptSkips, setAcceptSkips] = useState(false);
	const [step, setStep] = useState<AidokuImportStep>(1);
	const [selected, setSelected] = useState<string[]>([]);
	const seenDefaults = useRef(new Set<string>());
	return <Context.Provider value={{ aib, setAib, result, setResult, paused, setPaused, acceptSkips, setAcceptSkips, step, setStep, selected, setSelected, seenDefaults }}>{children}</Context.Provider>;
}
export function useAidokuImportSession() {
	const session = useContext(Context);
	if (!session) throw new Error('Aidoku import requires the application session');
	return session;
}
