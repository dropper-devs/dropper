import { useReducer } from "react";
import type { Kind, RowID, ListState } from "@/components/demo/data";

/**
 * The panel's row model as a reducer, mirroring ShareStore.swift. Making the
 * list a reducer removes the old `listRef` mirror: the async upload tick can
 * append a row with a plain `addRow` dispatch instead of reading a ref, and
 * every derived mutation (delete/archive also prune selection) lives in one
 * place.
 */
export type ListAction =
  | { type: "toggleSelect"; id: RowID }
  | { type: "masterSelect"; visible: RowID[]; allSelected: boolean }
  | { type: "clearSelection" }
  | { type: "deleteRows"; ids: RowID[] }
  | { type: "archiveRows"; ids: RowID[]; archive: boolean }
  | { type: "addRow"; kind: Kind };

const INITIAL_LIST: ListState = { rows: ["seed"], archived: [], selected: [] };

function listReducer(state: ListState, action: ListAction): ListState {
  switch (action.type) {
    case "toggleSelect":
      return {
        ...state,
        selected: state.selected.includes(action.id)
          ? state.selected.filter((s) => s !== action.id)
          : [...state.selected, action.id],
      };
    case "masterSelect":
      return { ...state, selected: action.allSelected ? [] : action.visible };
    case "clearSelection":
      return { ...state, selected: [] };
    case "deleteRows":
      return {
        rows: state.rows.filter((r) => !action.ids.includes(r)),
        archived: state.archived.filter((r) => !action.ids.includes(r)),
        selected: state.selected.filter((r) => !action.ids.includes(r)),
      };
    case "archiveRows":
      return {
        ...state,
        archived: action.archive
          ? [
              ...state.archived,
              ...action.ids.filter((r) => !state.archived.includes(r)),
            ]
          : state.archived.filter((r) => !action.ids.includes(r)),
        selected: state.selected.filter((r) => !action.ids.includes(r)),
      };
    case "addRow":
      return { ...state, rows: [...state.rows, action.kind] };
  }
}

export function useListState() {
  return useReducer(listReducer, INITIAL_LIST);
}
