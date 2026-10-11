# TV Horizon parity evidence

All images use synthetic fixtures. The TV captures are from a disposable Apple
TV 1080p simulator on tvOS 27.0, with the operator-only validation launch route
and live services disabled. Top Shelf images show the production renderer
in memory inside that simulator; they do not prove Home Screen placement.

- `tv-before.png` and `top-shelf-before.png`: source baseline `d29abb0`.
- `proposed-shared-board.png`: existing host-rendered Horizon board, used in
  the design note before implementation; it is a composition proposal.
- `tv-healthy.png`, `tv-dense.png`, `tv-saved.png`, `tv-failed.png`,
  `tv-empty.png`, `tv-loading.png`: revised TV account surface.
- `top-shelf-healthy.png`, `top-shelf-dense.png`, `top-shelf-saved.png`,
  `top-shelf-counts.png`: revised Top Shelf renderer, including anonymous mode.

The design note and source handoff live on [#811](https://github.com/cbusillo/context-panel/issues/811).
Physical acceptance follows the matching signed device delivery in #808.
