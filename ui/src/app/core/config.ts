/** Constants the design names (Phase 3 LLD). Values that change per deployment belong in environments, not here. */
export const ADD_LEAF_MODEL = 'ADD_LEAF';          // LLD §6.1: the add-leaf workflow model
export const MAINTAIN_MODEL = 'MAINTAIN';          // scope extension: every other steward change (drafts not started by add-leaf)
export const CHILDREN_PAGE = 200;                  // LLD §5.2: children page size ("Show next 200")
export const REVEAL_MAX_PAGES = 5;                 // LLD §7.2: beyond this, pin the search result
export const SEARCH_MIN_CHARS = 2;                 // LLD §5.1: in-tree search needs 2 characters
export const SEARCH_DEBOUNCE_MS = 300;             // LLD §5.2
export const PREFERENCE_DEBOUNCE_MS = 2000;        // LLD §5.2: remember the last hierarchy
export const WORKLIST_PAGE = 50;                   // LLD §5.2
export const ROW_HEIGHT_PX = { compact: 28, comfortable: 36 } as const;   // matches --nx-density-row-height
export const WORKLIST_VIEWS = ['assigned', 'urgent', 'overdue', 'claimed', 'submitted', 'drafted', 'participated',
  'notified', 'all'] as const;
export type WorklistView = (typeof WORKLIST_VIEWS)[number];
export const NODE_KINDS = ['legal_entity', 'structural', 'fund', 'partnership', 'trust', 'government_body',
  'natural_person'] as const;
export const VERSIONS_PAGE = 50;                   // Phase 3 LLD V.6: the Versions page lists 50 at a time
export const WORKING_VERSIONS_LIMIT = 50;          // the context-bar picker offers the first 50 working versions
export const VERSION_BASES_LIMIT = 100;            // "Copy from" in the new-version dialog offers the latest 100 versions
