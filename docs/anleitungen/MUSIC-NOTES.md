# Music Notes in Wupsy

[Deutsch](MUSIKNOTEN.md)

A Music Notes layer lets you float notes across your wallpaper, send them along a curve, or place a single treble clef. Use the Edit Canvas to arrange your scene. In **Live Preview**, you can see how the notes move and how the layers overlap.

## Add Music Notes and choose your symbols

1. Open your wallpaper in the Wupsy editor. If you’re starting with an image from the library, choose **Edit Wallpaper…**.
2. Click **+** next to **Layers / Effects** and choose **Music Notes**. Select the new layer in the list to see its settings in the inspector.
3. Under **Placement**, choose **Animate along route**. Turn on the symbols you want to use. The choices are **Quarter note**, **Eighth note**, **Double eighth note**, and **Treble clef**. At least one symbol stays selected. The treble clef starts out unchecked on a new layer.
4. Set **Note count**, **Size**, **Color**, and **Opacity**. An opacity of `1` is fully visible, and `0` is fully transparent. Set the note count to `0` to show the staff lines on their own.

> **Screenshot placeholder – Getting started.** Show the editor with the plus menu open and **Music Notes** highlighted. A second crop should show all four symbol toggles and several visible notes in Live Preview.

## Move in a straight direction, along a line, or around a loop

| How you want the notes to move | What to set in the inspector |
| --- | --- |
| Freely across the rectangular movement area | Choose **Linear**. Use the arrow buttons or **Direction (°)** to set the direction. The right arrow is `0°`. When the notes reach an edge, they reappear on the opposite side. |
| Along a fixed straight line | Choose **Path**. Turning it on for the first time creates a horizontal line. Use **Path templates** → **Straight line** to reapply that template. |
| Around an oval | Choose **Path**, then **Path templates** → **Ellipse**. This template is **Closed**. The notes continue from the end back to the start without fading. |

On an open path, moving notes fade out at the end and fade in again at the other end. Use **Forward** or **Reverse** to change the travel direction. Set **Speed** with the slider or the number field. At `0`, notes stay in place and can still float or rock.

**Path templates** replace the current curve. To hide a custom curve for a while, switch to **Linear**. Switching back to **Path** brings it back. **Delete Path** removes the saved curve.

## Draw your own Bézier path

An **anchor** is a point the curve passes through. The **grips** on the selected anchor shape how the curve approaches and leaves that point.

1. Choose **Path**, then **Edit Path**. The curve and its anchors appear on the **Edit Canvas**. On an open path, the square, orange dot, and arrow show the start, end, and direction of travel.
2. Double-click the curve to add an anchor at that spot. The curve keeps its shape until you move something. Try dragging the new anchor upward to turn a straight line into a bend.
3. Select an anchor and drag its grips to smooth the curve into the next segment. Drag the anchor itself to move the whole point. Anchors and grips stay within the movement frame.
4. Select an anchor you no longer need and press **Delete**. Keep at least two anchors. Press **Escape** to cancel a drag in progress.
5. Click **Finish Path Editing** to return to the movement frame. Drag inside the frame to move it. Drag a side to resize one dimension or a corner to resize both. This lets you reposition or resize the entire curve in the image.

> **Screenshot placeholder – Editing a curve.** Show an open curve with a middle anchor selected and both grips visible. Label the anchor, grips, start, end, and direction arrow. Keep **Finish Path Editing** visible in the inspector.

## Staff lines, floating, and rotation

### Style the five staff lines

Under **Staff**, turn on **Show staff lines**. In **Path** mode, the middle line follows your curve. In **Linear** mode, it runs through the center of the movement frame in the chosen direction.

- **Line spacing** controls how far apart the five lines are. **Line thickness** must be smaller than the spacing.
- **Line color** and **Line opacity** are independent of the notes’ color and opacity.
- The lines can overlap on tight bends. Make the bend wider or reduce the line spacing.

### Make the notes float and rock gently

Under **Gentle motion**, **Gentle float** makes the symbols drift slightly from side to side across their direction of travel. Set how far they drift with **Hover strength** and how often the motion repeats with **Hover frequency**.

**Gentle rocking** tilts a symbol back and forth. **Rocking strength** sets how far it tilts, and **Rocking frequency** sets how often it rocks. You can use floating and rocking together.

### Place or rotate a single symbol

- **Place freely** shows one **Symbol**. Drag it into place on the Edit Canvas or enter **X (canvas)** and **Y (canvas)**.
- **Attach to path** holds the symbol at the chosen **Path position (%)**. Turn on **Align with path tangent** to point it along the curve at that spot. With no active path, it stays at the center of the movement frame.

For a single symbol, choose **No rotation**, **Gentle rocking**, or **Rotate continuously** under **Rotation mode**. For continuous rotation, set **Rotation direction** and **Seconds per revolution**. A longer time means a slower spin. **Image plane (2D)** spins the symbol like a clock hand on the image. **Vertical axis (2.5D)** makes it narrow like a card turning edge-on, then shows its mirrored back. The two directions can look the same in this mode. Floating works with any rotation mode.

## Put notes in front of or behind an image layer

For notes that always pass behind an image, use the layer order. An image layer in front of the notes covers them wherever it is opaque. To switch sides along the route, use **Depth changes**.

1. Choose **Animate along route** and turn on **Path**.
2. Under **Depth changes**, select the image you want in **Foreground layer**. Make sure **Enable depth changes** is on. To pass behind a person, use a separate foreground layer with the person cut out against a transparent background, such as a PNG. A flat photo covers the notes wherever it is opaque. A foreground layer added with **Add Image…** works as a target.
3. Under **At path start**, choose **In front of image layer** or **Behind image layer**.
4. Click **Add change point**. Enter a **Path position (%)** between the start and end, then choose the side under **After this point**. You can add up to eight change points. Give each point a different value greater than `0` and less than `100`.
5. To hide the five visible staff lines behind the image as well, choose **Notes and staff lines** under **Apply depth changes to**. With **Notes only**, the lines keep their usual position in the layer order.

Notes remain visible through transparent parts of the image. Partially transparent areas or lower image-layer opacity cover the notes only partially. A change point in the middle of an opaque area can make notes disappear or reappear suddenly. For a natural transition, put the point just outside the silhouette where possible.

## Use perspective to go from large to small or small to large

**Perspective** makes the notes look as though they are moving away from you or coming closer. It works with **Animate along route** on an active open path. It changes how large the notes look along the route while keeping their speed steady. If the staff lines are on, their spacing and thickness change along the path as well.

1. Choose **Path** and **Open**. Turn on **Perspective**.
2. To go from **large to small**, set **Size at path start (%)** to `100` and **Size at path end (%)** to `30`. These are also the defaults.
3. To go from **small to large**, click **Swap start and end**. The route now starts at `30` and ends at `100`. Both fields accept values from `10` to `200`.

The start and end refer to the curve as drawn. In **Reverse**, the notes travel through the size change in the opposite direction. **Swap start and end** changes only how the size varies along the path. On a closed path, Wupsy suspends perspective so the size stays continuous at the join. The saved values take effect again when you return to an open path with moving notes.

> **Illustration placeholder – Size along the path.** Show two views of the same open path with **Forward** selected. Mark the start and end in both views. Show `100 → 30 %` at the top and `30 → 100 %` below, with visible notes and the corresponding inspector values in each view.

## Three examples to try

### 1. Float notes from left to right

1. Add a Music Notes layer. Choose **Animate along route** and **Linear**.
2. Click the right arrow under **Direction (°)**. Start with **Note count** at `8`, **Size** at `48`, and **Speed** at `24`.
3. Turn on **Gentle float** and leave **Gentle rocking** off for now. Watch **Live Preview** to see whether the pace suits the image.

### 2. Make notes disappear behind a person

1. Start with a background image. Use **Add Image…** to add a cutout of a person with a transparent background.
2. Add **Music Notes**. Choose **Path** → **Path templates** → **Straight line**, then **Edit Path**. Double-click the line near the middle of the image to add an anchor and drag it up a little. Use its grips to shape a soft bend that crosses the person at shoulder height.
3. Select the image of the person under **Foreground layer**. Turn on **Enable depth changes** and set **At path start** to **In front of image layer**.
4. Add two change points. Try `35` and `65` as starting values. Choose **Behind image layer** after the first point and **In front of image layer** after the second. Adjust both percentages to suit where the curve crosses the person. To hide the staff lines as well, turn them on and choose **Notes and staff lines**.

> **Screenshot placeholder – Hiding notes behind a person.** Show the cutout figure against a simple background. In Live Preview, the notes should be visible on either side of the figure and disappear behind its outline. Show the selected foreground layer and both change points in the inspector.

### 3. Make notes grow as they come toward you

1. Choose **Animate along route**, **Path**, **Straight line**, **Open**, and **Forward**. If needed, use **Edit Path** and drag the end anchor down a little. The route now leads from higher up in the image toward the foreground.
2. Turn on **Perspective** and, starting with the default values, click **Swap start and end**. Check that **Size at path start (%)** is `30` and **Size at path end (%)** is `100`.
3. Let **Live Preview** play. The notes start small and gradually grow as they approach the end. If they get smaller in the preview, check **Forward** and both percentage values.

## If something looks different from what you expected

- **I can’t see any notes.** Check that the Music Notes layer is visible, **Note count** is above `0`, and **Opacity** is high enough. Also check for an opaque layer in front.
- **The notes aren’t moving.** Check **Live Preview**, **Speed**, and **Placement**. A freely placed or attached symbol stays in place. The Edit Canvas shows a single symbol in its neutral pose.
- **Large notes barely get any bigger.** A small movement frame limits the visible size of moving notes and symbols attached to the path. Make the frame larger or try a smaller base size to make the perspective change easier to see.
- **The restart at the end of the path looks abrupt.** On a short path at high speed, the fade can be hard to see. Reduce **Speed** or lengthen the path. **Closed** paths have no end fade. Different depths at the start and end can still cause a visible change at the join.
- **The depth-change target is missing.** Choose an eligible, visible image layer. If the selected target is hidden or missing, the usual layer order applies. Single symbols have no **Depth changes** or **Perspective** controls.
- **I want to start over.** **Reset to Defaults** restores the default settings and switches to **Linear**. It keeps the curve you drew and the movement frame. Use **Save** to keep your finished scene.

[Back to the English editor guide](../EDITOR.md) · [Technical documentation for Music Notes](../effects/MUSIC-NOTES.md)
