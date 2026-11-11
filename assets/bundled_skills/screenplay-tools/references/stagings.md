# 导演文档编辑

导演操作统一使用 `Run stagings`。按剧情安排调度时，读取本次剧情依据和目标导演文档；按参考图搭独立场景时，读取参考图和目标导演文档，无需预读无关正文。先确定要表达的空间关系与镜头职责，再选择所需的站位、姿势和运动。

## 主要用途与制作粒度

导演台用于安排人物站位、朝向、前后遮挡、关键姿势、整体运动、机位、运镜与切镜，输出构图静帧或白模预演，供后续图片／视频生成参考。

用户要求“搭导演台”或“做一场预演”时，默认先把空间关系、运动方向和镜头节奏表达清楚。按镜头需要选择粒度：构图用站位与静态姿势；动态调度再加起止位置、运动路径、运镜和切镜；需要表达姿态变化时才补少量完整姿态关键帧。不要默认把整场戏拆成逐关节的精细表演，也不要为补齐正文描写自行制作呼吸、表情或特效动画。

导演台支持姿势调整和姿态关键帧插值，不提供动作库、动作片段编排、动作素材应用、自动步态、IK 或物理碰撞。姿势预设只提供一个姿态，路径只移动人物，不会自动生成走路、跑步、踢击或倒地过程。手动姿态过渡用于粗略表达动作节拍，不承诺自然步态、自动贴地、握持或接触解算。

道具只搭建影响站位、遮挡、运动终点或构图的必要占位，优先使用内置 GLB 的基础几何、家具、建筑环境、剧情道具和武器轮廓。精细外观、表演和特效交给后续生成。需要更精确的动作参考时，说明能力边界和所需外部素材，不把静态姿势或整体位移说成完整动作。

验收以镜头中能看懂人物关系、关键姿势、运动方向和切镜意图为准。简化不能导致主体意外出画、支撑物悬空或关键关系不可见；交付时说明实际做了哪些调度、哪些表演细节留给后续生成。

## 查询能力与现有内容

调用格式为 `{"command":"stagings","subcommand":"操作名","options":{...}}`。下表列出 options；导演命令需要剧本或画布作品与当前会话的媒体操作能力。

| subcommand | 必填 options | 可选 options 与行为 |
|---|---|---|
| `schema` | 无 | options 使用空对象；返回文档结构、单位、范围、控制规则与 commands 参数 |
| `presets` | 无 | `catalog`、`ids`，详见下方查询规则 |
| `list` | 无 | options 使用空对象；返回目录，不含 document |
| `create` | 无 | `title`、完整 `document`；省略 document 创建空白工程 |
| `read` | `staging_id` | `collection`、`id`、`frame`；frame 仅用于 tracks 且必须同时传 id |
| `apply` | `staging_id`，以及 `edits`、`commands` 至少一种 | 局部原子修改，不接受 document 或 title |
| `write` | `staging_id`、完整 `document` | 整份替换，不接受 edits、commands 或单独 title |
| `restore` | `staging_id`、`version` | version 为非负整数历史快照版本，整份替换 |
| `remove` | `staging_id` | 被引用的导演文档不可删除 |
| `sample` | `staging_id`、`frames` | 1–12 个整数帧，可以包含可编辑终点 |
| `frames` | `staging_id`、`frames` | 1–12 个整数帧；`camera_mode=sequence` 默认按切镜，fixed 必须传 `camera_id` |
| `preview` | `staging_id` | 刷新画布预览 |

`read` 的返回结构随读取范围区分：

| options 中的读取范围 | 返回内容 |
|---|---|
| 只有 `staging_id` | `id/title/version/document`，完整文档在 `document` |
| 加 `collection` | `staging_id/version/entries`，每项为 `{id, data}`，资源字段在该项 `data` |
| 再加 `id` | `staging_id/version/id/data`，单项资源在 `data` |
| tracks 单项再加 `frame` | `staging_id/version/id/frame/data`，该帧属性键在 `data` |

collection 可选 `objects/cameras/tracks/motion_paths/camera_moves/camera_cuts`。集合查询用 `result.entries.map(entry => entry.data)` 取得资源，不从 `result.data` 读取整个集合。`frames` 同步返回带帧号的图片拼图，不保存到素材或画布。

需要编辑完整文档或自定义字段时再查询 `schema`。`schema` 返回当前文档、姿态、属性、路径、机位目标、运镜与切镜的字段、类型、单位、范围和控制规则；`presets` 默认返回道具、姿势、机位和运镜的 ID 目录，各分类都是对象数组，每项只有 `id`。传 `catalog=props|poses|cameras|moves` 只查询该类；再传非空 `ids` 数组获取指定条目的完整详情。`ids` 必须配合 `catalog`，未知分类或 ID 会报错。姿势详情的 `variants` 数组同时返回各人物模型的 `geometry_key` 和完整 `pose`，查询不传模型参数；机位详情仍只有 ID。以这些查询结果为准，不自行拼另一套字段定义。

从当前工作区上下文的 `staging_id` 或制作画布导演节点的 `ref_id` 定位导演台，用 `Run stagings read` 读取 `version` 和完整 `document`。读取、编辑、恢复、采样、预览或删除已有导演台时，包括重试，都必须携带真实 `staging_id`。`schema`、`list` 不接受参数，使用空 `options`；`presets` 只接受 `catalog`、`ids`；`create` 新建独立文档，不传 `staging_id`。新建从空白工程开始，不加载场景模板。

`read` 可按 `collection` 读取对象、机位、属性轨、路径、运镜或切镜，再按 `id` 读取单项；读取某个属性键时传轨道 `id` 和 `frame`。身份来自实际返回值，不能用人物目录 ID 代替场内人物实例 ID。

## 编辑与原子批次

局部修改用 `apply`，整份替换用 `write`。

`apply` 只接收 `staging_id`、局部资源 `edits` 和编辑命令 `commands`；后两者至少提供一种，不接收 `document` 或顶层 `title`。先合并所有 `edits`，再按顺序执行 `commands`；整个请求成功才保存，失败不留下部分修改。未涉及的内容保持原样，无需重传 `motion_paths`、`camera_moves` 等集合。批次命令字段由 `schema.commands` 查询。

`write` 只接收 `staging_id` 和完整 `document`，不接收 `edits/commands`。先完整读取再替换，保留文档和内部资源 ID，以及所有必填字段；没有运动路径或运镜时，`motion_paths` 和 `camera_moves` 也必须显式写 `[]`。已有内容不能为了补齐字段直接清空。`create` 若显式传入 `document`，同样要求完整；省略则创建空白文档。

- `edits` 是对象数组，每项用 `op` 指定 `create/write/remove`，用 `collection` 指定集合、`id` 定位资源、`data` 提供字段。新资源用 `create`；已有资源用 `write`，它不会创建不存在的资源。创建时可省略 `id`，`results` 按输入顺序返回实际 ID；同批需引用新资源时显式提供唯一 UUID。修改只传需要改动的字段。编辑 tracks 中的单个姿态或属性键时，额外传 `frame` 定位该键。
- `commands` 复用编辑器的行为。`set_key` 按 `target_id/property/frame` 新建或更新键，不必先创建轨道；未提供 `easing` 时保留当前键的缓动。`remove_key` 删除末键时移除轨道。
- 文档级修改也用命令：`set_title` 传 `title`；`set_duration` 传 `duration_frames`，缩短后存在越界动画时拒绝，不自动裁剪；`set_output` 传完整 `output`（width、height、background 及可选 aspect_mode），只替换输出设置。灯光使用已有的 `set_base/set_key`。
- `set_base` 只改没有动画控制的基础属性。有动画时用属性键，不能改一个最终又被动画覆盖的基础值。
- `upsert_path/upsert_move` 的 `data` 使用领域 schema。改变控制区间若会替换已有控制，必须显式传 `replace:true`；先读现有控制再决定。`bake` 将指定路径或运镜转换为键，保留模式与区间外结果，无法满足误差或容量时整次失败。
- `add_camera` 使用机位预设；`set_camera_mode` 在指定帧保留构图，已有方向动画必须先显式处理。`set_cut` 按帧 upsert 切镜，`set_default_camera` 设置首切点前使用的机位。`command_results` 返回实际资源 ID。

例如创建一个立方体道具，由接口生成 ID：

```json
{
  "command": "stagings",
  "subcommand": "apply",
  "options": {
    "staging_id": "{staging_id}",
    "edits": [
      {
        "op": "create",
        "collection": "objects",
        "data": {
          "kind": "prop",
          "name": "占位箱",
          "geometry_key": "prop.cube.v1",
          "position": [0, 0, 0],
          "rotation": [0, 0, 0, 1],
          "scale": [1, 1, 1],
          "color": "#B7A48B",
          "pose": "none",
          "visible": true
        }
      }
    ]
  }
}
```

成功后从 `result.results[0].id` 取得新对象 ID，再用它修改位置：

```json
{
  "command": "stagings",
  "subcommand": "apply",
  "options": {
    "staging_id": "{staging_id}",
    "edits": [
      {
        "op": "write",
        "collection": "objects",
        "id": "{object_id}",
        "data": {"position": [2, 0, 0]}
      }
    ]
  }
}
```

新增机位可用 `add_camera`，从 `command_results` 取得新机位 ID 后再调整构图。

例如在第 24 帧记录位置，在第 48 帧切换机位：

```json
{"command":"stagings","subcommand":"apply","options":{"staging_id":"{staging_id}","commands":[{"op":"set_key","target_id":"{actor_id}","property":"position","frame":24,"value":[2,0,0],"easing":"smoothstep"},{"op":"set_cut","frame":48,"camera_id":"{camera_id}"}]}}
```

`scale` 是 `[x,y,z]` 三轴缩放，每个分量必须在 **0.1 至 10（含边界）**。对象基础值和动画关键帧都受此限制；演员必须三轴等比，道具可以非等比。不要用 0 或 0.01 表示隐藏；隐藏和出现使用 `visible`，对应动画键使用 `hold`。

批次失败表示其中所有改动均未保存。重试前核对错误与当前内容，重新提交该批尚未完成的改动；不能只补一个修正项就认为整批已完成。参数不完整的调用未执行，需要重新提交合法调用。大量动画按独立动作阶段分批，前批成功后再继续；相互依赖的创建、引用和引用修复留在同一批，不反复重写整份大文档。

应用预设使用 `apply_pose`，传 `target_id`、`preset`，无需传模型或完整姿态。程序从目标人物读取 `geometry_key` 并展开对应参数；传 `frame` 时按 `set_key` 新建或更新该帧姿态键，不传时按 `set_base` 修改基础姿态，已有姿态动画时拒绝。命令结果的 `id` 为目标人物实例 ID。

自定义姿态时，从当前采样或 `presets` 的 `catalog=poses`、`ids` 查询取得完整姿态；详情在 `poses[].variants[]` 中，按目标人物的 `geometry_key` 选择，再改需要的角度或高度。每个姿态键保存完整 26 参数。姿势预设仅填姿态，不改世界走位。人物整体走位与朝向使用对象 `position/rotation`；姿态里的身体旋转属于模型内部变换，不代替人物整体转向。

机位朝向分 `free` 和 `look_at`，字段互斥。注视目标使用完整的 point/object/bone 描述，偏移属于目标的局部空间；骨骼目标随本帧姿态求值。需要转向独立动画时用 free 旋转键，需要跟踪人物时用动态引用。切镜决定使用哪台机位，运镜只改变单台机位。

删除对象会移除其专属控制；默认机位、切镜和其他机位的注视引用必须在同批 `edits` 中显式处理。整份替换前必须完整读取，保留文档和内部资源 ID，不用局部列表拼出完整文档。写后回读并核对无关内容和引用。

修改自动保存并同步打开的导演台。同轮对话保留修改前历史快照；`restore` 使用实际快照版本替换整份文档。用户与 Agent 同时编辑同一字段时以后写入为准。

## 预设目录

### 人物模型

新建人物时显式填写 `geometry_key`。已有实例沿用其保存值，应用姿势不重新选择模型。人物库添加会按资料性别选择；资料未指定时当前使用男性人偶作为默认外形，不据此推断人物性别。

| 模型 | geometry_key |
|---|---|
| 男性人偶 | `actor.male.v1` |
| 女性人偶 | `actor.female.v1` |

### 姿势

以下 ID 用于 `apply_pose.preset` 或姿势详情查询，男女模型共用同一套 ID。走路、跑步等名称表示动作中的静态姿态。

| 分类 | ID |
|---|---|
| 站立与展开 | `neutral`、`t_pose` |
| 坐、蹲与跪 | `sit`、`squat`、`kneel`、`kneel_both` |
| 行进姿态 | `walk`、`run` |
| 身体姿态 | `hands_hips`、`lean`、`bow`、`think`、`arms_crossed`、`phone` |
| 动作姿态 | `fight`、`kick`、`throw`、`push` |
| 手势 | `wave`、`point`、`raise_hand`、`cheer` |

### 道具

以下 ID 可直接用作道具的 `geometry_key`。名称用于选型，尺寸和接触关系仍查询详情。

| 分类 | ID |
|---|---|
| 基础形状 | `prop.cube.v1`、`prop.cylinder.v1`、`prop.cone.v1`、`prop.sphere.v1`、`prop.capsule.v1`、`prop.torus.v1`、`prop.tube.v1`、`prop.plane.v1` |
| 家具与设施 | `prop.table.v1`、`prop.chair.v1`、`prop.bench.v1`、`prop.bed.v1`、`prop.counter.v1`、`prop.sofa.v1`、`prop.coffee_table.v1`、`prop.television.v1`、`prop.floor_lamp.v1`、`prop.suitcase.v1`、`prop.monitor.v1`、`prop.open_shelf.v1`、`prop.filing_cabinet.v1`、`prop.whiteboard.v1`、`prop.booth_seat.v1`、`prop.wardrobe.v1`、`prop.refrigerator.v1`、`prop.dining_table.v1`、`prop.conference_table.v1`、`prop.school_desk.v1` |
| 建筑环境 | `prop.wall.v1`、`prop.column.v1`、`prop.platform.v1`、`prop.stairs.v1`、`prop.doorframe.v1`、`prop.office_partition.v1`、`prop.folding_screen.v1`、`prop.window_frame_sill.v1`、`prop.door_leaf.v1`、`prop.railing.v1`、`prop.trash_bin.v1`、`prop.road_barrier.v1` |
| 剧情道具 | `prop.service_trolley.v1`、`prop.wheelchair.v1`、`prop.iv_stand.v1`、`prop.hospital_bed.v1`、`prop.storage_chest.v1`、`prop.wooden_rack.v1`、`prop.lantern.v1`、`prop.candlestick.v1`、`prop.phone.v1`、`prop.cup.v1`、`prop.documents.v1`、`prop.book.v1`、`prop.keys.v1`、`prop.single_bed.v1`、`prop.double_bed.v1` |
| 武器 | `prop.dagger.v1`、`prop.sword.v1`、`prop.saber.v1`、`prop.spear.v1`、`prop.staff.v1`、`prop.axe.v1`、`prop.hammer.v1`、`prop.shield.v1`、`prop.bow.v1`、`prop.pistol.v1`、`prop.rifle.v1` |

### 机位

| ID | 含义 |
|---|---|
| `current` | 通用初始机位（通过 add_camera 新建，不复制视口） |
| `front_medium` | 正面中景 |
| `front_close` | 正面近景 |
| `side_close` | 侧面近景 |
| `over_left` | 左侧过肩 |
| `over_right` | 右侧过肩 |
| `high_45` | 高位斜俯视 |
| `low_angle` | 低角度仰视 |
| `bird` | 鸟瞰 |
| `dutch` | 倾斜机位 |

### 运镜

标为“需要主体”的运镜要求机位处于 `look_at` 模式，且 `camera_target` 为 object 或 bone 引用。

| 分类 | 需要主体 | ID |
|---|---|---|
| 基础 | 否 | `static`、`pan_l`、`pan_r`、`tilt_u`、`tilt_d`、`dolly_in`、`dolly_out`、`zoom_in`、`zoom_out`、`truck_l`、`truck_r`、`handheld`、`slide_reveal`、`fly_through`、`whip_pan`、`crash_zoom` |
| 基础 | 是 | `foreground_pass`、`rack_focus` |
| 跟随 | 是 | `follow_pan`、`follow`、`lead`、`side_follow`、`orbit`、`orbit_half`、`orbit_full` |
| 空间 | 否 | `crane_up`、`crane_down`、`rise_out`、`spiral_up`、`spiral_down`、`aerial` |
| 空间 | 是 | `fpv`、`dive` |

## 道具选择与摆放

从道具目录选择模型标识，再用 `presets` 的 `catalog=props`、`ids` 查询选中道具的米制尺寸、包围盒、原点、朝向、默认摆放和支撑面高度。通用圆柱与建筑圆柱的基础尺寸不同；餐桌、会议桌、课桌等按用途选取，不凭名称猜尺寸。

模型顶点已按米建好，通常保持 `scale=[1,1,1]`。需要指定外尺寸时，按目标尺寸除以模型基础尺寸计算三轴缩放。平面高度为零，放在 XZ 平面，可从两面观察；缩放不能把它变成有厚度的实体。GLB 已采用 Y 向上坐标，不再补转 90 度。

底面原点的道具在无旋转、`position.y=0` 时落地。武器使用握持点原点，坐标零点以下可能仍有柄或杆；新建的默认位置只负责初始落地，持物时把对象位置移到手掌对应的世界位置，再调整旋转。刀剑和长杆沿 +Y，枪和弓瞄向 +Z，具体方向仍以目录为准。没有自动握持、骨骼挂载、接触解算或物理模拟；人物运动时不会自动带动武器。

坐面、桌面、床面和架面用 `support_heights_m`，不要拿包围盒总高度代替。无旋转时，世界支撑高度为对象位置 Y 加上局部支撑高度乘以 Y 缩放；旋转后需要按对象完整变换计算并检查画面。窗框需按窗台位置抬高，门板与门框分别摆放；灯具、屏幕、轮子、抽屉等只提供静态轮廓，不会自动发光、转动或开合。手机、文件和书默认平放，具体朝向与支撑关系以目录及实际画面为准。

## 采样与画面检查

`sample` 传 `staging_id` 和最多 12 个整数帧，返回对象、完整姿态、各机位、有效机位、灯光和诊断。按关键姿势、运动起止、切镜前后和终点抽样；涉及接触关系时补查对应帧。随机读取不改变播放状态。

`frames` 按关键姿势、接触、运动起止和切镜前后选取最多 12 帧，返回带帧号和机位标注的拼图。交付前必须用它检查主体是否出画、支撑物是否落地、接触关系是否可见；`sample` 用于核对数值，不能代替看图。

完成编辑与检查后调用一次 `preview` 刷新画布第 0 帧切镜序列图片。保存不会自动刷新画布；生成失败时说明实际状态，不能把已保存说成已更新预览。

## 交付

Agent 完成编辑、画面检查和预览刷新后，说明修改内容与待确认之处。由用户在导演台界面确认效果，再输出图片或视频到制作画布；不通过 AI 命令导出独立文件。

独立文档用 `remove` 删除；仍被制作节点引用时需先处理引用。
