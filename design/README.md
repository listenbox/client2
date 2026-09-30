# Desktop design bridge

The parent Listenbox repository's `DESIGN.md` is the visual authority. This
directory holds its generated token snapshot so the client repository can build
and check independently. Do not edit the snapshot or generated Dart values.

From the parent workspace, regenerate with
`dart apps/client2/tool/design.dart --source DESIGN.md`. `moon run
root:desktop-design-check` compares the snapshot with that canonical contract.
The check also participates in the parent lint workflow and affected CI tasks.

`moon run client:lint` verifies generated Dart against the snapshot and rejects
raw colors, type sizes/weights, corner radii, and seeded palettes in desktop
widgets. UI consumes
`DesignTokens` through `ListenboxTheme`; native controls receive explicit light
and dark color roles, system fonts, capsule actions, field geometry, and focus
states. Native action and field dimensions come from the component definitions.
Typography uses Flutter's nearest supported font-weight step. Layout
dimensions remain specific to this desktop surface.

The recording-studio identity is expressed through the quiet work area,
achromatic navigation, readable rows, and clear states. Product UI uses no
homepage imagery. Design changes belong in the parent contract and its linked
system files, followed by regeneration here.
