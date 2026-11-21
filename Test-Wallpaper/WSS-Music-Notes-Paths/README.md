# Music Notes path playback

Original synthetic, asset-free Wupsy fixture under the repository LICENSE.
Import this directory or its scene.wss.json in the development build.

- Gold notes follow the open S-curve from left to right with a fade at each end.
- Blue notes follow the closed ellipse in reverse, crossing the rightmost join
  without an endpoint fade.
- Both layers have five evenly spaced notes, hover and rotation. Use Live
  Preview or desktop playback. Change speed to zero to inspect stationary
  spacing while hover and rotation continue. Turning those switches off makes
  the layer static.

Both paths are preconfigured. Select either layer and choose Edit Path to see and
edit its curve. The selected layer shows the curve and its blue movement
rectangle in both modes. Transform handles appear outside path editing, and
anchors and Bézier handles appear during path editing.
