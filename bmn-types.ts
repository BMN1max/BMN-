export type Theme = 'dark' | 'light';
export type Accent = 'blue' | 'violet' | 'cyan' | 'silver';
export interface BMNProject { title: string; category: string; tags: string[]; description: string; }
export interface BMNConfig { version: string; roadmapGroups: number; plannedEnhancements: number; }
