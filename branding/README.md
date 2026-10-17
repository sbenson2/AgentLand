# AgentLand circus-tent identity

The tent is the logo: a steamboat-style three-quarter circus big top drawn by PixelLab
(below), with a striped roof, pennant, scalloped valance, tied-back curtains and a dark
doorway. It is the logo everywhere (owner, 2026-10-12): the iPhone and Mac icons in the
night ramp, the in-app mark (`AgentLandMark`) in the backdrop's ramp and a hand-drawn Mac
menu-bar template; and since the same evening it is Home's tent, the exact same pixels
(owner: "the new tent in the logo also needs to be the new tent on teh home screen", then
"it needs to be the exact same pixel art"). Home draws the tent and its broad pixel title
in the clown's existing five-tone day/night ramps, using crisp nearest-neighbor edges and
stepped highlights. Loading covers use the same tonal frames and night ramp as Home on slate. The title uses the PixelLab AgentLand Rubber Hose font.

The shared circus clock, reveal lifecycle and six-character cast are preserved.
Doorway travel curls onto and off the orbit with matching tangents; the rider
moves and fades inside the opening, with complementary doorway/foreground masks.
Home measures its title, tent, quip and actions against the available safe-area
height rather than the opening cover's center anchor. Decoration contracts before
button space; short-wide Home places the tent beside the actions. Reduce Motion,
inactive scenes and hidden/covered surfaces show the still artwork.

## Current artwork

- Home's tent is `tent-logo-pixellab-source.png` (the logo sprite, `tent-logo.json`), pixel for
  pixel: `tent-home.json` records how it is packaged. Every pixel with alpha 128 or more takes the
  nearest of the riders' five day tones by the weighted distance 0.3/0.59/0.11, exactly as
  `scripts/package-logo.py` maps the logo; the packaged images are the 113×113 window from (10, 7)
  of the 128×128 sprite (only clear pixels are cropped). The scene draws them at 2.125 pt a sprite
  pixel (240.125 pt square) centred in the 336 × 360 scene: the tent is 214.6 × 212.5 pt, centred on
  x 168, its lowest pixel at y 285.2, like the old big top (215.25 pt wide, ground line 285).
  `TentArtworkTests.testHomeTentIsTheLogoSpritePixelForPixel` checks every pixel. The big top it
  replaced (PixelLab Pro Flash, seed 26100201, 2026-10-02), its loop, records and packaged
  resources are in `archive/2026-10-12-tent-before-logo/`.
- `tent-loop/frame-00.png` … `frame-11.png`: source frames from PixelLab PixMiniMax job
  `58da1478-f136-4a80-82a6-5323253cf413`, seed 26101332, drift threshold 0, prompt
  `TENT_LOOP_PROMPT` (`scripts/candidates/circus.py`), calmed on 2026-10-13 at the owner's request
  ("too strong"): once a loop the roof's slopes lift by about a pixel and settle, and the pennant
  flutters every frame (3.4% of the tent's pixels change on average, 6.7% at most; the 2026-10-12
  loop, seed 26101206, swelled the roof and dipped the valance, 13% and 29%). The still in the day
  tones was supplied as first and last frame; frame 00 is its exact copy, and the 13th image (the
  model's redraw of the still) is not used. Packaging maps every frame to the day tones and copies
  source rows 53–127 (the valance and its scallops down) from the still, so the valance, walls,
  curtains and doorway remain fixed; the generated frames already match there pixel for pixel.
  `tent-loop.json` records the job, the 39 other candidates, the motion measure and the cleanup;
  the candidates and previews stay in `.evidence/icon-redesign-20261012/home-tent/loop-subtle/`.
- `TentTone.png` and `TentToneLoop.png` in the shared package: still and 12-frame
  tonal artwork, alpha 0/255, with the doorway removed. Day colors map by index to
  the existing night ramp. Playback remains 0.1 s per frame on the circus clock.
- `tent-mono.png` / `tent-mono-white.png`: compatible templates,
  using tones 1–3 as ink and lighter details as holes. `package-tent.swift` writes
  these, the tonal resources and aligned depth masks together.
- `tent-doorway.png`: 763 opening pixels, from darkest-tone seed (51, 90) in source
  pixels, bounded by x=37…65, y=67…107 (27…55, 60…100 in the packaged window). A
  solid-core flood and one-pixel growth preserve the shaded curtains, their ties and
  the valance's centre scallop. `TentGeometry.json` records the measured bounds and
  the packaged side and drives the clown's entrance and threshold. The opening remains a
  hole filled beneath the mark with `AgentLandTheme.tentDoorway` (#1B222C).
  `python3 scripts/check-tent-doorway.py <out.png>` produces a visual overlay.
- `tent-depth-mask.png`: complete tonal silhouette with enclosed holes filled,
  doorway included. Each breathing frame has its aligned depth
  mask in `TentLoopDepth.png`; depth only hides the clown behind the tent.
- The Home tent's one-colour menu-bar template (`tent-menubar.png`, `TentMenuBar.png`) is no
  longer packaged: the Mac menu bar uses the logo's hand-drawn glyph (`tent-menubar.txt`,
  below); the last copies are in `archive/2026-10-12-tent-before-logo/`.
- `tent-isometric-pixellab-source.png`: the original 96×96 PixelLab Pro Flash
  isometric tent, seed `20260924`, job `85e43bb0-af6e-4edd-8cb3-f9ac851302dd`.
  Its outlined edits (`tent-outline-weight-edit.json`, `tent-depth-mask.json`)
  produced the outlined mark, archived in `archive/2026-09-23-outlined/`. The
  frontal detailed tent that briefly replaced it re-centred the door and read
  front-on; it is archived in `archive/2026-09-23-frontal-detailed/`.
- `clown-unicycle-pixellab-source.png`: 96×96 right-facing clown, generated with
  PixelLab Pro Flash, seed `202609223`, job
  `ffaf1ead-06d4-4e7c-9dd2-f5670e7af4c8`, using the tent as a style reference.
- `clown-unicycle-white.png`: one-color white/transparent cleanup,
  `42b79fff-cc77-487b-9641-79839daf730d`. The generation's light areas become
  transparent details and its ink becomes white; see `clown-unicycle-cleanup.json`.
  The shared package contains this exact PNG as `ClownUnicycle.png` (the still
  `AgentLandClownMark`).
- `clown-ride/<design>/`: the six riding clowns, `whiteface` (cone hat), `auguste`
  (big bow tie), `tramp` (derby), `harlequin`, `ringmaster` and `strongman` (bald,
  kiss curl), all revised together in PixelLab on 2026-10-02 with rubber-hose limbs,
  pie-cut eyes, white gloves and big shoes, in the existing five-tone palette. The owner found the two-tone riders' legs, shoes
  and unicycle "messy and obscure" and asked for "a palette of tones … like real
  pixel art".
  - **The palette.** `clown-ride.json` records the indexed five-tone ramp:
    1 outline, 2 dark fill, 3 mid, 4 light, 5 white. The day tones are for the
    paper Home, and the lifted night tones for dark Home and the empty-chat
    landing on slate.
  - **The designs.** PixelLab Pro Flash creates the six related designs.
    Candidate manifests retain the original jobs, prompts and cleanup
    provenance. The approved complete 72-frame loops preserve these character
    designs and the fixed palette.
  - **The motion.** Each design is a PixelLab one-piece 96×96 loop of 72 source
    frames (`frame-00.png` … `frame-71.png`). Candidate preparation scripts time
    the gloves to the juggling balls and redraw the unicycle and boots into the
    source frames; the runtime consumes the complete sprite and does not draw a
    unicycle or assemble moving limbs. The source motion is 1/60 s per frame, 18
    frames per beat, a 1.2 s ride loop and a 20.1 s orbit. Candidate manifests
    retain the PixelLab jobs, seeds, prompts and measured near/far glove centers.
    The pose, costume and waist recipes below describe the preceding 12-frame
    pipeline, preserved in the pre-gold archive. They do not generate the active
    72-frame loops.
  - **New PixelLab work.** Read `../docs/PIXELLAB-GUIDE.md` first. The 72-frame
    loops were built from chained 12-frame calls; the guide's "Why animation frames
    garble" measures the seams this causes and its rules give the fix (not yet
    applied to these loops).
  - **Archived poses.** `clown-ride/source/pose.py` wrote `first-frame.png`,
    `poses.json` and `rig.json`:
    - both hips on the saddle;
    - the feet on the crank circle 180° apart through a full clockwise turn in
      12 frames;
    - each ankle 7 px above and 2 px behind its pedal, where the big shoe's sole
      meets it;
    - knees solved from an 11 px thigh and a 14 px shin, always bending forward;
    - a 1 px drop of the head and shoulders on every beat.
  - **Stable costume colors.** PixelLab exact guarded edits preserve the reviewed
    head, hat and chest colors through the one-pixel bob. The six juggling poses
    repeat identically in the second half of the pedal cycle. Stationary trouser
    pixels retain their source colors instead of changing with the nearest leg.
    `candidates/clown-motion-polish-20261002/color/` records the source masks,
    palette mapping and immutable PixelLab outputs. Its historical row-62 body
    copy is superseded by the contour repair below; do not rerun it as a final pass.
  - **Shoes and leg shading.** Each clown reuses its own reviewed shoe pixels at
    a fixed sole position on each pedal, with a consistent darker far-shoe ramp.
    Exact ankle and old-foot cleanup keeps the silhouette connected. The near
    leg uses the mid tone and the far leg the dark tone; fixed costume pixels
    are protected. `shoe-ownership.json` identifies visible near/far shoe pixels
    so the wheel cannot split a shoe based on the nearest posed leg. Small ankle
    connectors have separate optional `nearAnkle`/`farAnkle` ownership. The
    candidate `feet/` recipes record these exact PixelLab edits.
  - **Raised thighs.** The knees rise above the waist, so their original posed
    contours and continuous near/far shades must cross the old row-62 split.
    `candidates/clown-waist-20261003/` records exact PixelLab repairs for the six
    old designs' 72 frames in total. `leg-ownership.json` keeps each visible near thigh in
    front of the saddle; protected glove pixels stay in the foreground and
    constrain palm measurements without treating nearby costume highlights as
    part of the glove. Leg, foreground and shoe/ankle ownership are disjoint.
  - **Interior leg shading.** The 2026-10-03 refinement uses guarded
    PixelLab edits to blend dark fragments inside near-leg cloth into its mid
    tone, preserving the opaque outer contour and all other ownership.
    Recipes: `candidates/clown-interior-shading-20261003/`; before/after loops:
    `../.evidence/clown-interior-shading-20261003/review.html`.
  - **Complete-source prototype.** The owner redirected the work on 2026-10-03
    toward one complete clown-and-unicycle sprite. The separate whiteface study
    is in `candidates/clown-one-piece-20261003/`; `orientation-pixel/frame-00.png`
    keeps the far leg behind the wheel and adds matching shoe details, distinct
    pedals/cranks and a clear seat post using PixelLab edits. Both shoes point
    right; a guarded canvas edit corrects the previously mirrored rear boot. Its base
    preview is `../.evidence/clown-one-piece-20261003/base.html`. The manifest
    records earlier animation attempts and verification status. The final
    `animation-research-final/` loop from this study is now the active whiteface
    source; the other five final loops are in `candidates/clown-gold-20261003/`.
  - **Packaging.** `python3 scripts/package-clown-gold.py` first validates all
    six designs and writes nothing on a failed frame. It copies the 72 source
    frames and provenance into `clown-ride/<design>/`, writes each 6912×96
    `ClownRide-<design>.png` strip and motion JSON with 72 near and far palms,
    and archives the former sources/resources at
    `archive/2026-10-03-clown-before-gold/`. Validation covers 96×96 dimensions,
    binary alpha, the five tones and exact palm counts. Swift tests check the
    main silhouette and wheel ground row. It also writes `JugglingBall.png` as eight 16×16 frames
    in a 128×16 strip. The 128×16 choice resolves the earlier ambiguous “8×16
    strip” wording while preserving eight 16×16 sprites. The legacy
    `swift scripts/package-clown-ride.swift` is retained as a buildable command
    but exits with its retirement guard for these designs; it no longer produces
    active clown artwork.
  - **In the app.** The app draws each complete frame in the ramp of the surface
    it sits on, with a two-pixel ring around the silhouette in the backdrop's
    colour where the rider crosses the tent. Juggling uses the ball strip, tinted
    by the selected seven-colour ball identity while preserving sprite alpha;
    held balls keep their landed spin frame and airborne balls select the frame
    from their signed spin. The 16×16 sprite contains an 8×8 ball inside padding;
    the app draws its canvas at 18 pt (9 pt visible diameter before scene scaling)
    so the balls remain visible on iPhone Home and Chat. Held, airborne and dropped
    balls share this size and backdrop ring (visibility follow-up, 2026-10-08).
  - **Former 12-frame hub visibility.** The big shoes covered the hub and the near crank when that foot
    is in the lower half of its turn. The whole hub shows in frames 4–8, and the
    near crank stem in frame 6, ending beneath the shoe on its pedal.
- `logo-light.png` / `logo-dark.png`: the logo tent in day tones on white and in
  night tones on slate, written by `scripts/package-logo.py` (the clown head's on 2026-10-12, the Home
  tent's before).
- `tent-bounce-light.gif` / `tent-bounce-dark.gif`: standalone tent-motion
  previews. The complete loading scene is native SwiftUI, not these GIFs.

## App icons, logo and loading colors

The app icon of iPhone, iPad and the Mac is one layered Icon Composer icon,
`ios/AgentLand/AppIcon.icon`, with iOS 27 glass (owner, 2026-10-17, design "B: tent 7×":
"Your pixel tent as an iOS 27 layered glass icon, slightly smaller for more breathing room,
like Apple's icons"). The owner asked on
2026-10-12 for the tent in the steamboat PixelLab style of the clown head that had replaced
it that day ("lets go back to the tent logo, just make the tent look like the style we
reserched here,", then "t3 me like" and t3-2): `tent-logo-pixellab-source.png` is a 128×128
PixelLab generate-image-v2 (Pro) sprite, drawn from the Home tent with the clown logo
(`archive/2026-10-12-clown-logo/`) as its style image; `tent-logo.json` records the job,
prompt, references and packaging. `python3 scripts/package-logo.py` writes the icon's
`icon.json` and its three images: `tent.png`, the sprite in the riders' five day tones, ×7
with nearest-neighbour, centred on a clear 1024 canvas and 8 px below centre, in a glass group
with the system's specular highlight and a neutral shadow at 0.5 (no translucency);
`tent-mono.png`, its image for Clear and Tinted (`tinted` specialization), the same tent with
one grey per tone (28, 80, 140, 205, 255, from the day tones' luminance); and `bg.png`, an
opaque vertical gradient from #3D4A5C to #222B37 in a group without glass. The background is
an image because ictool 27 ignores a `fill`'s `dark` specialization and draws System Dark;
the image keeps the slate in Dark. The Mac target references the same folder. The same
packager writes the in-app mark `LogoMark.png` (day
tones cropped to the tent and padded to a 101×101 square; `AgentLandMark` recolours it to
night on a dark backdrop) and the menu-bar template `LogoMenuBar.png` with its double
`LogoMenuBar-2x.png` (below). A navy #1E2C4D was
tried on 2026-09-24; the owner asked for the slate theme back the same day. The flat
icons before 2026-10-17 (the tent ×8 on #27313F for every iPhone appearance, ×7 in the Mac's
rounded square) are in git history. The runtime loading screen resolves the same shared dark
colors, including the status bar. It does not change the saved appearance setting.

The opening cover (lock, host connection, loading) shows the tent alone, breathing:
the doorway's dark fill under the shaded tent, whose loop is `contents` keyframes on Core
Animation's render server, so Face ID and loading cannot hold it. With no clown to
hide, the cover draws no depth mask. Reduce Motion produces a still tent. The cover
can continue through Face ID's temporary inactive state while authentication is in
progress; other inactive states and the background pause it.
`AgentLandCircusLoading.prepareArtwork()` decodes the loop, the tent's images, the
balls, the rope, the title's letters and, last, the clowns in a detached
utility-priority task; called behind the cover, it keeps that work off the main
thread when Home is revealed. The scene reads the clowns only through
`AgentLandClownArtwork.prepared`, which never waits for the decode: until it is
done the stage has no clown, and clowns decoded after the reveal start the show
then, so the first still curls out of the doorway.

On Home and the empty-chat landing (`workSurface`) the scene runs on a native
timeline at 60 fps, and the clowns perform (`AgentLandCircusChoreography`).
When the surface is revealed (`revealedAt`, or the first moment it animates), a
clown fades in inside the doorway on the next beat, drawn between the doorway's
fill and the tent (masked by `TentDoorway.png`) and, below the threshold, in front
of the tent through complementary masks. It moves down inside the opening while
fading in, then curls down-left and up-left onto the near orbit. A separate inward
curl leaves the ring below the doorway and turns into it, fading while moving
inside. Cubic Hermite tangents match the orbit velocity at both joins. It circles
every 20.1 s (67 beats), facing its direction of travel, with the depth mask hiding it behind the tent. The ring is a
circle seen at an angle, 163.3 points wide (the 13-pixel tyre's 9.75-point radius times the 16.75 ride loops in a lap)
and 104 deep, so the clown moves at the wheel's own speed, 51.05 points a second, and the tyre never slips; the
odd number of beats keeps every phase of the lap open to a performance's juggling clock. The rider plays its PixelLab
72-frame ride loop at 1/60 second per frame. Juggling follows the measured palms
with gravity 694 sprite px/s² and a seeded sequence of alternating three- and
four-ball stretches, each 12–30 beats. The initial count uses weights 0.6/0.4;
with only two counts, excluding a repeated count requires alternation thereafter.
Misses have a 3% chance at eligible catches, are at least 40 beats apart and
never occur during the first 12 beats. A replacement comes from the pocket
within two beats, keeping the normal 0.5-beat lead before its throw. A missed
ball leaves the juggling count at the catch but remains visible while falling
and rolling; its tint stays reserved throughout. The
clown starts with empty hands and takes the balls out of its pocket once it is on
the ring. After a seeded 40–90 s it throws no more, finishes its catches, rides back
in at a door pass after a conservative catch/run-out bound and fades out; 4–10 s later the next design comes
out, shuffled and never the same twice in a row. Every ball has a
one-pixel backdrop-coloured ring so it stays visible over the rider. The eight
16×16 spin frames are multiplied channel by channel by one of the seven rainbow
tints. A new pocket ball takes a random free tint; continuing balls keep theirs.
Throws spin at 1.0–2.4 turns/s in the horizontal throw direction, held balls
retain their landed angle and rolling spin follows travel. Everything is a pure,
seeded function of the shared circus clock; each performance juggles on its own
clock, whole ride loops from it, so the orbit and the juggling line up as on the
clock's reference lap. Reduce Motion shows the still tent and no clown. A hidden
or covered surface, an inactive scene and the background keep the selected stage without a clown.

About one reveal in three (one Home load; drawn from the reveal's own seed, so Home and the landings agree) is
on the tightrope, every performance until the next reveal (owner's request, 2026-10-04: the stage is fixed for a
load, not drawn per clown). Only the chosen stage is visible from its first frame
(owner, 2026-10-08): a tightrope reveal shows `TightropeRig.png` immediately, a ring
reveal shows the tent, and neither crosses into the other. Stage selection uses the
shared reveal's seed before the clown sprites finish decoding. Until the shared
reveal exists, no provisional stage is drawn. Between clowns the rope is empty. The rig is a PixelLab
Pro Flash rope between two striped poles (seed 26100601, reduced onto the five day tones, recoloured for night like
the tent), drawn at the tent's 2.625 points a pixel, centred on the tent with the poles' feet on the ring floor at
y 340. Each clown fades in over 0.4 s riding away from the rope's left end (the first after a 0.6 s entrance pause),
crosses four times juggling and fades out riding back into the left end. Each crossing nets 18 beats of riding; about half go straight
across, about a third roll back two to four beats somewhere in the middle of the rope (after 5 to 12 beats) and
go on, and the rest rock back and forth a beat at a time before going on. The wheel rolls exactly as far as the
pedals turn it, so the tyre never slips whichever way it goes. Half the acts turn round at each end with a hop
(owner's request, 2026-10-04): riding on into the end the clown squashes down over 0.2 s (85% tall, a little
wider), springs up stretched (110% tall, a little narrower) and is its own shape again at the top of the hop, two
beats in the air, 23.4 points high (a ball's gravity over that airtime), the wheel spinning freely over the same
spot while the clown spins round about its wheel, narrowing to a quarter of its width edge-on and widening again
mirrored, and lands facing the other way, upright, squashing a little (90% tall for 0.05 s, back by 0.25 s),
then wobbles. The others face right throughout and ride the
return crossings backward, the ride frames counting back down. Every reversal of the pedalling (an end ridden backward, a roll back and its end) falls in the middle of a
hold (12 frames past a throw), where counting the frames backward closes each glove exactly while the juggling
holds a ball in it, and the palms are read from the frame shown, so a reversed stretch is a reverse cascade.
Within six frames of a reversal (half a hold) the pedalling slows to a stop and back along a parabola instead of
snapping round, still showing only frames that close the hand. The rope's free run between the platforms is
drawn live in the rig's dark tone, one rig pixel thick in 0.75-point columns, straight from each platform's edge
down to the wheel: it gives up to 11 points under the wheel in the middle (4·s·(1−s) of that at share s of the
run, none on the platforms), dips a little on each pedal push and bounces, dying away, after every reversal and
turn. It is drawn between the rider's cut-out ring and the rider, so the wheel sits on it. The rider leans about
its wheel's contact: it sways (three seeded sine waves, about ±4°, strongest mid-rope), leans 1.2° the way it is
riding, leans hard (5.5°) the new way just before each reversal, as a unicycle follows its rider's lean, then
wobbles, and wobbles after each turn; the lean is held within ±9°. A ball dropped from the rope keeps falling from
the wheel to the floor and bounces and rolls there. `-AgentLandCircusAct tightrope` (a launch argument) puts every
reveal on the tightrope, for watching and tuning it.
`scripts/package-tightrope.py` validates the rig (binary alpha, the five day tones, an unbroken rope row whose
free run between the platforms is one stretch of one tone) and writes `TightropeRig.png` and `TightropeRig.json`
(rope row, ends, free run and the poles' bottom row) and keeps the source in `tightrope/`.

Each appearance has its own seed derived from the reveal seed. Its finite ball
schedule is cached; there is no repeating 168-beat phrase. Return planning uses
the rig's safe maximum run-out to avoid constructing hundreds of expired ball
schedules during stale-reveal catch-up; drawing uses the exact seeded schedule.

App lock and host connection retain their shared window-based cover anchor.
Home uses its independent safe-area launcher measurement.
Authentication starts automatically and has no app-owned button.
The circus stays through project discovery and the selected screen's initial
content, empty state or connection error. The saved workspace appearance is
prepared behind the dark cover; a display-frame acknowledgement completes the
handoff. Routine background polling does not restart the loading scene.

The Mac menu bar uses a pixel-exact 22-point template image (`AgentLandMenuBarIcon`) whose
1x and 2x bitmaps are `LogoMenuBar.png` (22×22) and `LogoMenuBar-2x.png` (the same pixels
doubled, 44×44), so it is never resampled. Its tent is not the sprite: `tent-menubar.txt` is
a 21×19 glyph drawn by hand for the bar's 1x grid (`#` opaque, `+` alpha 120, `.` clear),
the dome, scalloped valance and curtains around a round door, solid so the bar paints it
mostly white in Dark (owner, 2026-10-12: "it should be mostly white", "round is tent door").
At 1x a resampled painting blurred to grey. It and the app icon remain static.

## Arched title and quips

Home's arched "AGENTLAND" wears one of nine faces in one of five looks, picked
afresh at every entrance (each Home load) and never the same face or look twice
running (owner's request, 2026-10-04).
The default and layout face is the PixelLab-generated AgentLand Rubber Hose, with
rounded 8-bit forms matching the tent and six clowns. The quip remains under the
tent. `branding/wordmark.json` records provenance, geometry, motion and every face.

- **Faces.** `AgentLandWordmarkFaces`: AgentLand Rubber Hose, Holtwood One SC,
  Bungee, Chango, Alfa Slab One, Titan One, Bowlby One SC, Shrikhand and Coiny.
  The eight open-licence faces are SIL OFL 1.1 files from google/fonts, each
  bundled with its `<Name>-OFL.txt`; `wordmark.json` "faces" records each file's
  source and SHA-256. They are read straight from their files (never registered),
  and `AgentLandWordmarkFont.licenseText`, shown in Settings, lists every notice.
  Each face runs through the same rasterizer; a broad or slanted face is drawn at
  the widest letter width from 1.12 down to 0.9 at which no two neighbours share
  a pixel and every letter lies within three pixels of Rubber Hose's canvas
  (Chango and Shrikhand come out a little narrower). Faces that fail to load are
  left out; without Rubber Hose there is no title.
- **Looks.** `AgentLandWordmarkLook`, all in the five ramp tones: `bevel` (the
  original stepped shading), `extrude` (two pixels of depth down-right, outlined),
  `candyStripe` (diagonal white/mid stripes inside the outline), `dropShadow` (the
  letter two pixels down-right in the outline tone) and `doubleOutline` (a second,
  white outline on slate, dark on paper). The inline stripe was tried and left out.
- **Letter boxes.** `WordmarkFontSet` gives each of the nine letters one fixed box:
  the union of every face's glyph box, one pixel more to the left and top, two to
  the right and six below (looks and drips). Every face and look is painted into
  it, so changing font mid-animation is only an image change of the letter and
  its mask. The layout canvas stays Rubber Hose's.

- **Font.** `AgentLandRubberHose.ttf` comes from PixelLab `create_font`, job
  `325cd550-a0cc-4f71-959e-e343543e7c8f`, seed 26100250, 16 px Bold glyphs.
  `AgentLandWordmarkFont` registers it once per process and checks the PostScript
  name `AgentLandRubberHose`; nothing is installed system-wide. The former
  Holtwood font and OFL notices remain packaged.
- **Geometry.** Letters sit on a circle centered at scene (168, 640), radius 680,
  over a 42° sweep. The font's cap height is 48 units (size 54.857, tracking
  +9.268), widened by 1.12 before rasterization on the tent's 2.625-unit grid.
  The symmetric canvas is 551.25 × 112.875 units. Tests verify clearance from
  all clown and ball paths, including the doorway curls.
- **Rendering.** `AgentLandWordmark` remains one accessibility header over a
  `UIView`/`NSView` with one `CALayer` per letter. The explicit `tonalArt` option
  supplies five-tone bevels with dark edges and stepped highlights; default
  callers retain tint/mask rendering. `AgentLandTitleBlock` retains quip
  advancement and prefetch, and the existing per-letter animation masks.
- **Motion.** Twelve entrances (drop and bounce, marquee light-up, flip-in, arc
  unfurl, pixel assemble, curtain wipe, toss-up, spin-in, slot shuffle through the
  faces, ink fill, stamp, stretch-snap; 0.9–1.4 s) play when Home is revealed, never
  on the opening cover, each with a newly picked face and look. Thirteen idle
  flourishes (bulb chase, ripple, loose letter, juggle hop on the clown's 0.3-second
  beat, marquee blink, font-morph flip, font-morph dissolve, jelly wobble, domino
  tip, sparkle twinkle, spotlight sweep, leapfrog, drip and reform) follow every
  20–30 seconds and on a tap, which also shows the next quip. The two morphs show
  another face in the same look and end on the load's face; sparkles light each
  pixel once and the spotlight lifts letters a tone, so only the marquee blink
  dims anything. They are Core Animation keyframes on
  `transform.*`, `opacity` and `contents` only, never `position`. A seeded picker
  never repeats an animation twice in a row, nor the previous launch's last
  entrance. The marquee blink dips twice, 0.6 s apart. The motion gate is the
  circus's: still under Reduce Motion, when hidden, covered, inactive or in the
  background, and with `-AgentLandUITestsDisableAnimations`.
- **Placement.** `HomeLauncherLayout` places the title near the safe-area top,
  followed by tent, quip and compact actions, with at least 32 points below the
  buttons. Ordinary text sizes use a fixed frame; accessibility sizes scroll
  when needed. Short-wide layouts place the artwork beside the actions.
  `AgentLandTitlePlacement` remains available for other callers, while Home
  measures its own launcher.
- **Quips.** `QuipStore` keeps a saved ring of at least eight, read synchronously,
  and never shows one of the last 50 again. About 2 s after Home is revealed, a
  detached utility-priority task asks Apple's on-device model
  (`SystemLanguageModel.default`, guided generation) for eight around a random
  circus theme; each is validated (one line, 3–36 characters, no emoji, quotation
  marks, markup or links). When Apple Intelligence is off or unavailable, or on any
  error or refusal, `GrammarQuipProvider` (an in-house seeded Tracery-style grammar
  with 145,922 valid combinations) writes them instead.
  `-AgentLandFixedQuip "<text>"` pins one quip for UI tests.

## Packaging

From the project root:

```sh
swift scripts/package-tent.swift
swift scripts/render-brand-assets.swift
```

The first writes the tonal artwork, geometry, templates, doorway, depth mask, menu-bar template and the
tent loop (`TentLoop.png`, `TentLoopDepth.png`, `TentLoop.json`) from the PixelLab
exports; the second copies the tent template and doorway into the shared package and refreshes
the tent bounce previews, drawing the doorway in #1B222C beneath the mark. It leaves the logo (iPhone and Mac
icons, in-app mark, menu-bar template, `logo-light/dark.png`), which `scripts/package-logo.py` writes, unchanged. The renderer packages PixelLab artwork;
it does not redraw it. App Store icon PNGs are RGB without alpha.

The riders are packaged by `python3 scripts/package-clown-gold.py`. It validates
all six 72-frame one-piece sources before writing outputs and records the
pre-gold archive and candidate provenance. The former
`swift scripts/package-clown-ride.swift` remains buildable for compatibility but
exits through its retirement guard for these designs.
`scripts/candidates/circus.py` makes and logs this round's PixelLab jobs.

The still clown sprite is an exact PixelLab export copied into
`shared/AgentLandBranding/Sources/AgentLandBranding/Resources/`; the tent mark,
doorway, depth mask, menu-bar template and loop are packaged from the PixelLab tent
by `scripts/package-tent.swift`; `ClownRide-<design>.png` and its motion
`ClownRide-<design>.json` are packaged from the complete 72-frame
`clown-ride/<design>/` sources by `scripts/package-clown-gold.py`. The title uses the packaged PixelLab-generated
`Fonts/AgentLandRubberHose.ttf`; the previous Holtwood font and OFL notice remain
packaged. Package resources include tonal and template tent frames, geometry,
doorway/depth masks, all six rider strips/rigs and font resources. Installed apps
must not depend on development cache paths. After replacing resources, verify
the built app's `AgentLandBranding_AgentLandBranding.bundle`; incremental Xcode
builds can retain older copies.
Source edits do not change an already running Mac service.

DEBUG simulator preview flags (never used for the installed phone launch):
`-AgentLandLoadingPreview`, optional `-AgentLandLoadingPreviewElapsed <seconds>`,
and `-AgentLandLoadingPreviewReduceMotion`. Normal and Release launches follow
actual host state.

## Preserved artwork

- `archive/2026-10-12-clown-logo/`: the clown-head logo of 2026-10-12, its provenance and the
  in-app mark and menu-bar template it shipped, replaced the same day by the steamboat-style tent.
- `archive/2026-09-23-bigtop-seed112/`: the PixelLab big top (seed 112) that the
  round-1 pick a605 replaced, with its provenance and packaged masks.
- `archive/2026-09-28-clown-two-tone/`: the six two-tone riders of 2026-09-27 (designs, rides and
  packaged sheets) that the five-tone redraw replaced.
- `archive/2026-09-27-clown-white-legs/`: the single white-legged rider that the
  six rubber-hose designs replaced (its poses spread the hips 10 px apart over a
  10 px crank, so its knees bent together in frame 06), with its references, poses,
  provenance and packaged strip.
- `archive/2026-09-23-clown-solid-legs/`: the ride frames, references, provenance
  and packaged strip of the clown with solid navy legs, replaced by white leggings.
- `archive/2026-09-23-outlined/`: the outlined tent with uniform two-pixel strokes,
  replaced by the detailed tent.
- `archive/2026-09-23-frontal-detailed/`: the detailed tent that re-centred its
  door and read front-on (rejected by the owner: "tent needs to be isometric still").
- `archive/2026-09-23-isometric-patched/`: the outlined isometric tent with detail
  patched in by one edit and two inpaints (rejected: "its not good right now").
- `archive/isometric-outline/`: the original thin outlined version.
- `archive/2026-09-22-filled/`: the filled version replaced in this revision.
  Its edits remain in `tent-fuller-edit.json` and `tent-fuller-cleanup.json`.
- `archive/2026-09-21-front-facing/`: the original front-facing tent; source
  `tent-pixellab-source.png`, Pixen seed `20260921`, job
  `24c535e1-b9a1-4864-b393-8df1ca7fe316`.
