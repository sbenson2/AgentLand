# PixelLab guide

Researched 2026-10-15 from PixelLab's v2 API spec, its MCP guide and docs pages, and
the papers under Research backing. Read this before any PixelLab generation in
AgentLand: new art, new animation or a repair. PixelLab claims below quote or
paraphrase the official sources at the end. The parameter names are the v2
API's; MCP tool names are given where they differ.

## Why animation frames garble

Each PixelLab call makes its frames from that call's inputs only. Within one call,
the frames stay close to each other. Between calls, nothing ties them together except
the inputs we pass, so drift appears at every join. PixelLab's rotation guide warns about
chaining generations: "errors will accumulate after each generation". In the clown's
72-frame loop, frame-to-frame changes at the joins between calls are more than twice
the size of changes inside one call (median 233.5 vs 99.5 upper-body pixels).

The research agrees. Processing each frame independently gives results that are
inconsistent over time (Lai et al., ECCV 2018). Consistent methods tie every frame to
one reference: cross-frame attention to the first frame (Text2Video-Zero), or
reference-image features plus a pose guider (Animate Anyone). Spatial conditioning
such as human pose controls a diffusion model's structure (ControlNet). An image
prompt avoids the prompt engineering that text alone needs (IP-Adapter). For cartoons,
interpolation that assumes linear motion fails on large exaggerated motion, and
live-action video priors need adapting before they fit (ToonCrafter).

## Tools and limits

| Tool | Use it for | Limits and key parameters |
| --- | --- | --- |
| Template animation: `animate_character` with `mode="template"` | Standard humanoid motion on a character already created in PixelLab | About 50 humanoid templates, e.g. `walking-8-frames`, `breathing-idle`. `ai_freedom` 0-900, template mode only; 0 means strict template following, and "lower values produce more consistent animations". `text_guidance_scale` default 8. |
| Skeleton v3: `POST /v2/animate-with-skeleton-v3`, or `animate_character` with `mode="skeleton-v3"` | Custom motion from our own poses | One sprite (`first_frame`, up to 256x256) plus 18-joint `keypoints` per output frame, 3 to 15 frames. PixelLab: it "moves the character instead of redrawing it each frame". `description` is appearance, `action` is a short motion label. `first_frame_keypoints` must be the pose `first_frame` is in. `view` (default `low top-down`) and `direction` must match the sprite. `template_id` picks the body (`mannequin`, `bear`, `cat`, `dog`, `horse`, `lion`). `seed` 0 means random. `no_background` defaults to true. `POST /v2/estimate-skeleton` returns keypoints for an image. |
| Text v3: `POST /v2/animate-with-text-v3`, MCP `animate_image` | Motion that no template or pose set covers | `frame_count` 4-16, even. Pixel budget: width x height x frames <= 524,288. The first frame is kept as frame 1. Optional `last_frame` interpolates toward an end pose. `seed`. `drift_threshold` is a colour de-flicker toward frame 1 (0 corrects every frame). `enhance_prompt` defaults to false. |
| PixMiniMax: `POST /v2/animate-pixminimax`, or `animate_character` with `mode="pixminimax"` | Longer text-driven clips | `frame_count` a multiple of 4 from 4 to 40. `description` is the motion: "Describe movement, not appearance". Caption fields `subject_description`, `initial_pose`, `view` and `direction` are read from the image when omitted. Keep `enhance_prompt` false so the text isn't rewritten. `last_frame`, `seed`, `drift_threshold`. |
| Pro animation | Multi-direction custom animation | Generates directions one after another, using the finished sides as reference (10-25 generations per direction). The animate-with-text Pro tool returns 16 frames for a 32 or 64 px reference, but only 4 frames for 65 px and above. |
| Character creation: `create_character`, `POST /v2/create-character-v3` | The approved still and its rotations | The reference image must face straight-on south: "whatever this sprite faces is taken as south". v3 output size 32-256 px; MCP `size` defaults to 48 (max 128 in standard and pro, 256 in v3). "Prompt complexity scales with size." `outline`, `shading`, `detail`, `proportions` presets (e.g. `heroic`), `text_guidance_scale` (default 8), `color_image` with `force_colors`. |
| Cleanup: `POST /v2/reduce-colors`, `POST /v2/unzoom` | Palette and pixel grid | `reduce_colors` quantizes all the frames passed in one call onto ONE shared palette (`num_colors` or `palette_image`). `unzoom` restores the true pixel grid of upscaled art. Several generation endpoints also take `target_palette` (beta, 2-256 hex colours). |

Cost notes from the spec: skeleton v3 bills 3, 8 or 15 frames as 2, 3 or 4
generations, so "prefer one long clip to several short ones".

## Rules

1. **One clip = one generation job.** Never chain clips (start a call from another
   call's generated frame) or patch frames with a different seed. If a frame is bad,
   regenerate the whole clip. Fit the clip to the tool: skeleton v3 takes up to 15
   frames, so make a 12-15 frame cycle, play it at about 12 fps and reverse it in
   code when needed.
2. **Approve a still first.** Generate or edit one base frame, get the owner's
   approval, then animate from that exact file.
3. **Short, fixed description.** The description is an appearance noun phrase:
   build + role + 3-4 colour blocks + 1-2 silhouette features + face. Use the
   identical string in every call for that character. Motion goes only in `action`
   (or PixMiniMax's `description`). The clown's descriptions were 738-844 character
   sheets reworded per batch.
4. **Prefer pose-driven animation.** Use template animation with `ai_freedom` 0, or
   skeleton v3. Next best is text v3 with a fixed `seed` and a low `drift_threshold`.
5. **Small and simple.** Keep animated characters at 48-64 px with low detail. Drop
   micro-detail (polka dots, thin face paint, strings). Give the limbs different
   colours, so crossing legs stay readable. AgentLand already does this with the near
   leg in the mid tone and the far leg in the dark tone.
6. **Pipeline.** Use one shared palette: `target_palette` at generation time, or a
   single `reduce_colors` over all frames together. Set `no_background` at
   generation time instead of removing backgrounds per frame. Scale only by integers
   with nearest-neighbour sampling. Don't make in-betweens with generic video
   interpolation (RIFE-type tools).
7. **Vague brief.** Turn the owner's words into the fields below, show the still,
   then animate. Don't animate from an unapproved design.

## Prompt templates

### Still (base frame)

```text
description: <build> <role>, <colour block 1>, <colour block 2>, <colour block 3>,
             <silhouette feature>, <face>
size:        48-64 px (AgentLand's riders are 96 px; new animated work should start smaller)
detail:      low
view/facing: the view and direction the animation will use; a reference for
             rotations must face straight-on south
palette:     target_palette or color_image + force_colors with the five tones
```

Clown example, in the five-tone day ramp (`#11161D`, `#354052`, `#66728A`,
`#B3BDCA`, `#FFFFFF`):

```text
stocky whiteface clown on a unicycle, white face and gloves, light gray cone hat,
slate suit, navy trousers and big navy shoes, pie-cut eyes and a wide smile
```

### Animation from the approved still

Skeleton v3, one pedal cycle in one call:

```json
{
  "description": "<the identical still description>",
  "action": "pedal",
  "direction": "east",
  "view": "side",
  "template_id": "mannequin",
  "first_frame": "<the approved still, PNG base64>",
  "first_frame_keypoints": "<the still's own pose: rig or /v2/estimate-skeleton>",
  "keypoints": ["<12-15 poses, one full pedal cycle>"],
  "seed": 26100451,
  "no_background": true
}
```

The seed is an example: pick one and keep it. For a template character, use
`animate_character(mode="template", template_animation_id="walking-8-frames",
ai_freedom=0)`. For text v3, the `action` describes movement only, e.g. "pedalling a
unicycle forward at a steady pace", with a fixed `seed` and a low `drift_threshold`.

## Pipeline checklist

- [ ] The brief is written as the fields above, and the owner approved the still.
- [ ] One clip per job, within the tool's frame limit. No `chainFrom`-style first
      frames and no patch calls with another seed.
- [ ] The `description` string is byte-identical across every request for the
      character (diff the request JSONs).
- [ ] One palette: `target_palette` at generation time, or one `reduce_colors` call
      over every frame with `palette_image` set to the five tones.
- [ ] `no_background` set at generation time.
- [ ] Display at an integer nearest-neighbour scale. A 96 px frame belongs in a 96 pt
      box (1x/2x/3x pixels), not a 72 pt one (0.75x/1.5x/2.25x).
- [ ] No generic video interpolation for in-betweens.
- [ ] Review the changed-pixel count between consecutive frames. A spike at a
      boundary means a seam.
- [ ] Record job ids, seeds and request JSON in the candidate manifest, as
      `branding/README.md` requires.

## Research backing

- Animate Anyone (Hu et al.): a reference network keeps the reference image's
  appearance details, and a pose guider drives the motion. https://arxiv.org/abs/2311.17117
- Text2Video-Zero (Khachatryan et al., ICCV 2023): cross-frame attention of each frame
  on the first frame preserves appearance and identity. https://arxiv.org/abs/2303.13439
- IP-Adapter (Ye et al.): an image prompt as the alternative to hard-to-engineer text
  prompts. https://arxiv.org/abs/2308.06721
- ControlNet (Zhang et al., ICCV 2023): spatial conditioning (edges, depth, human pose)
  for pretrained diffusion models. https://arxiv.org/abs/2302.05543
- ToonCrafter (Xing et al., SIGGRAPH Asia 2024): correspondence-based interpolation
  fails on cartoons' large non-linear motion, and live-action video priors need
  adapting; compressed latents lose fine detail. https://arxiv.org/abs/2405.17933
- Learning Blind Video Temporal Consistency (Lai et al., ECCV 2018): per-frame
  processing gives results that are inconsistent over time. https://arxiv.org/abs/1808.00449
- Sprite Sheet Diffusion (Hsieh et al.): diffusion models for sprite sheets, where every
  frame must keep the design, proportions and style consistent.
  https://arxiv.org/abs/2412.03685

## Sources

- PixelLab v2 API spec: https://api.pixellab.ai/v2/openapi.json
- PixelLab MCP guide: https://api.pixellab.ai/mcp/docs
- Animate with skeleton: https://www.pixellab.ai/docs/tools/animate-with-skeleton
- Animate with text (new): https://www.pixellab.ai/docs/tools/animate-with-text-new
- Rotating a character: https://www.pixellab.ai/docs/guides/rotating-a-character
