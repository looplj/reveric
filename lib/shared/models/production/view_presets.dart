// 职责: 定义图片预设与镜头/打光派生参数，在提交时展开预制提示词。
// 关联文件:
//   lib/shared/services/production/view_derive_orchestrator.dart
//   lib/shared/models/storyboard/prompt.dart
import '../storyboard/prompt.dart';

enum ViewPreset { camera, light, panorama }

/// 图片编辑器里的预设；只决定提交时拼在用户提示词前的预制指令。
enum ImageGenerationMethod {
  free,
  upscale,
  blocking_storyboard,
  storyboard,
  continuous_grid,
  plot_grid,
  after_3s,
  before_5s,
  portrait_texture,
  cinematic_light,
  panorama,
  multi_camera_grid,
  expression_grid,
  face_turnaround,
  character_sheet,
  character_turnaround,
  scene_sheet,
  product_sheet,
}

/// 这些预设是对参考画面的改写或推演，没有参考图无从下手。
const referenceRequiredMethods = {
  ImageGenerationMethod.upscale,
  ImageGenerationMethod.after_3s,
  ImageGenerationMethod.before_5s,
  ImageGenerationMethod.portrait_texture,
  ImageGenerationMethod.cinematic_light,
};

/// 预设独立于用户提示词；只在提交时展开。
class ImageGenerationPreset {
  const ImageGenerationPreset({
    this.method = ImageGenerationMethod.free,
    this.complexity,
  });
  final ImageGenerationMethod method;

  /// 用户选的复杂度。提交时由生图服务按型号校验：不支持该档时用目录默认值，型号没有复杂度时不发送。
  final String? complexity;

  factory ImageGenerationPreset.fromStyle(Map<String, dynamic>? style) {
    final json = style?['imageGeneration'];
    if (json == null) {
      return const ImageGenerationPreset();
    }
    final stored = (json as Map)['complexity'];
    return ImageGenerationPreset(
      method: ImageGenerationMethod.values.byName(json['method'] as String),
      complexity: stored is String && stored.isNotEmpty ? stored : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'method': method.name,
    if (complexity != null) 'complexity': complexity,
  };

  String assemble(String userPrompt, String? inputId) {
    if (method == ImageGenerationMethod.free) {
      return userPrompt;
    }
    if (inputId == null && referenceRequiredMethods.contains(method)) {
      throw const FormatException('This image preset requires a reference');
    }
    final instruction = expandImagePreset(method, inputId);
    return userPrompt.trim().isEmpty
        ? instruction
        : '$instruction\n\n$userPrompt';
  }
}

enum CameraFraming { extreme_wide, wide, medium, close, detail }

enum LightDirection { left, right, top, bottom, front, back }

enum LightBrightness { dim, moderate, bright, intense }

enum LightTexture { soft, hard }

enum LightTemperature { warm, neutral, cool }

class ViewPresetArgs {
  const ViewPresetArgs({
    this.yaw = 0,
    this.pitch = 0,
    this.framing = CameraFraming.medium,
    this.direction = LightDirection.front,
    this.brightness = LightBrightness.moderate,
    this.texture = LightTexture.soft,
    this.temperature = LightTemperature.neutral,
    this.description = '',
  });
  final int yaw, pitch;
  final CameraFraming framing;
  final LightDirection direction;
  final LightBrightness brightness;
  final LightTexture texture;
  final LightTemperature temperature;
  final String description;
}

const cameraYawFragments = {
  -180: '背面',
  -135: '左后侧',
  -90: '左侧面',
  -45: '左前侧 45°',
  0: '正面',
  45: '右前侧 45°',
  90: '右侧面',
  135: '右后侧',
  180: '背面',
};
const cameraPitchFragments = {
  -60: '低机位仰拍',
  -30: '微仰',
  0: '平视',
  30: '微俯',
  60: '高机位俯拍',
};
const cameraFramingFragments = ['大远景', '远景', '中景', '近景', '特写'];
const lightDirectionFragments = ['左侧', '右侧', '顶部', '底部', '前方', '后方（逆光）'];
const lightBrightnessFragments = ['柔和偏暗', '适中', '明亮', '强烈'];
const lightTextureFragments = ['柔光', '硬光'];
const lightTemperatureFragments = ['暖色', '中性', '冷色'];

String expandViewPreset(
  ViewPreset preset,
  ViewPresetArgs args,
  String? inputId,
) {
  final reference = inputId == null
      ? '描述的场景'
      : StoryboardPrompt.reference(inputId, '参考图');
  final extra = args.description.trim();
  return switch (preset) {
    ViewPreset.camera => _camera(args, reference) + extra,
    ViewPreset.light =>
      '以$reference为准，保持构图、人物、服装与场景完全不变，只重新布光：'
          '主光来自${lightDirectionFragments[args.direction.index]}，'
          '亮度${lightBrightnessFragments[args.brightness.index]}，'
          '${lightTextureFragments[args.texture.index]}，'
          '${lightTemperatureFragments[args.temperature.index]}光。$extra',
    ViewPreset.panorama => _panorama(inputId),
  };
}

String _camera(ViewPresetArgs args, String reference) {
  final yaw = cameraYawFragments[args.yaw];
  final pitch = cameraPitchFragments[args.pitch];
  if (yaw == null || pitch == null) {
    throw const FormatException('Unsupported camera preset');
  }
  return '以$reference为准，保持人物身份、外貌、服装、道具与场景布置不变，只改变拍摄机位：'
      '相机位于主体$yaw，$pitch，景别为${cameraFramingFragments[args.framing.index]}。保持原画面的光线与色调。';
}

String _panorama(String? inputId) =>
    '${inputId == null ? '根据用户描述，生成' : '以${StoryboardPrompt.reference(inputId, '参考图')}中的场景为依据，生成同一空间的'} 360°×180° 等距柱状投影全景图，'
    '宽高比 2:1。水平方向左右边缘无缝衔接，地平线位于画面垂直正中，'
    '顶部与底部完整覆盖天花与地面。画面中不出现任何人物，保留场景结构、陈设、材质与光线。';

String expandImagePreset(ImageGenerationMethod method, String? inputId) {
  final source = inputId == null
      ? '用户描述'
      : StoryboardPrompt.reference(inputId, '参考图');
  const keep = '人物身份、外貌、服装、场景与光线色调保持一致';
  const gutter = '格与格之间用细白线分隔，画面内不添加任何文字、编号或水印';
  return switch (method) {
    ImageGenerationMethod.free => '',
    ImageGenerationMethod.upscale =>
      '以$source为准，输出同一画面的高清版本：保持构图、人物身份、服装、道具、场景与光线完全不变，补全清晰细节，去除模糊、噪点与压缩痕迹，不添加新元素。',
    ImageGenerationMethod.blocking_storyboard =>
      '根据$source中的场景与人物，绘制一页调度故事板。上半部分是俯视平面图：'
          '标出场景主要陈设和每个人物的站位与编号，用带箭头的虚线画出人物走位路线，'
          '用相机图标加视锥标出各镜头的机位与拍摄方向，并按拍摄顺序编号。'
          '下半部分按镜头编号依次排列对应的分镜小画面，每格下方用简短中文注明景别与运镜。'
          '整体为干净的影视故事板手稿风格，$keep。',
    ImageGenerationMethod.storyboard =>
      '根据$source，延续同一场戏绘制一页故事板：按从左到右、从上到下排列 6 个镜头画格，'
          '画格之间留白分隔，每格左上角标注镜头编号，下方用简短中文注明景别、运镜与动作。'
          '镜头之间景别有变化，动作与视线方向连贯，$keep。',
    ImageGenerationMethod.continuous_grid =>
      '以$source为起点，生成一张 5×5 共 25 格的连贯分镜图：'
          '按从左到右、从上到下的顺序表现同一场戏连续推进的 25 个瞬间，'
          '相邻画格的动作自然衔接，景别与机位随剧情适度变化，$gutter。'
          '25 格中$keep。',
    ImageGenerationMethod.plot_grid =>
      '以$source为起点推演接下来的剧情，生成一张 2×2 四宫格：'
          '按左上、右上、左下、右下的顺序表现起、承、转、合四个关键情节节点，'
          '每格都是完整的电影画面，情节发展合乎逻辑，$gutter。四格中$keep。',
    ImageGenerationMethod.after_3s =>
      '以$source为当前画面，生成同一镜头 3 秒之后的画面：机位、景别、场景与光线保持不变，'
          '人物身份、外貌与服装不变，只顺着画面中正在进行的动作与情绪自然推进 3 秒，'
          '表现动作的后续发展与人物神态的变化。',
    ImageGenerationMethod.before_5s =>
      '以$source为当前画面，生成同一镜头 5 秒之前的画面：机位、景别、场景与光线保持不变，'
          '人物身份、外貌与服装不变，反推 5 秒前人物所处的位置、姿态与神情，'
          '使其能够自然发展为当前画面。',
    ImageGenerationMethod.portrait_texture =>
      '以$source为准，保持构图、人物身份、五官结构、表情、姿态、服装与场景完全不变，'
          '只提升人像质感：呈现真实自然的皮肤纹理与毛孔细节，去除塑料感与过度磨皮，'
          '发丝清晰分明，眼睛有自然的眼神光，肤色均匀通透，达到电影级人像摄影的细腻质感。',
    ImageGenerationMethod.cinematic_light =>
      '以$source为准，保持构图、人物、服装与场景完全不变，只做电影级光影校正：'
          '建立明确的主光方向与主次光比，暗部保留细节，高光柔和不过曝，'
          '加强轮廓光与前后景的空间层次，统一画面色调并做电影感调色，让光影服务于情绪与叙事。',
    ImageGenerationMethod.panorama => _panorama(inputId),
    ImageGenerationMethod.multi_camera_grid =>
      '以$source中的同一时刻为准，生成一张 3×3 多机位九宫格：'
          '九个画格分别从不同机位拍摄同一瞬间，覆盖正面、侧面、背面、俯拍、仰拍、过肩等角度，'
          '并兼顾远景、中景、近景与特写等景别，$gutter。九格中人物动作与$keep。',
    ImageGenerationMethod.expression_grid =>
      '以$source中的角色为准，生成一张 3×3 表情九宫格：同一角色的面部近景，'
          '依次表现喜悦、愤怒、悲伤、惊讶、恐惧、厌恶、沉思、羞涩、坚定九种表情，'
          '头部角度与光线统一，背景为干净的纯色，$gutter。'
          '九格中角色的五官、发型与妆容完全一致。',
    ImageGenerationMethod.face_turnaround =>
      '以$source中的角色为准，生成角色脸部三视图：在纯白背景上从左到右并排展示'
          '同一角色头部的正面、四分之三侧面与正侧面特写，平视机位，中性表情，'
          '柔和均匀的影棚光。三个视图的五官比例、发型与妆容完全一致，不添加任何文字。',
    ImageGenerationMethod.character_sheet =>
      '以$source中的角色为准，生成一张专业的影视角色设定图：纯白背景，'
          '左侧为角色全身正面立绘，右侧排列面部表情特写、服装细节、配饰与随身道具的局部特写。'
          '角色的身份、外貌、发型、服装与配色保持一致，不添加多余文字。',
    ImageGenerationMethod.character_turnaround =>
      '以$source中的角色为准，生成角色全身三视图：在纯白背景上从左到右并排展示'
          '同一角色的正面、侧面与背面全身站姿，自然站立、双臂微微张开，'
          '三个视图的身高与比例对齐，柔和均匀的影棚光。'
          '外貌、发型、服装与配饰完全一致，不添加任何文字。',
    ImageGenerationMethod.scene_sheet =>
      '以$source中的场景为准，生成一张专业的影视场景设定图：主画面为场景的整体主视角，'
          '周围配以其他角度的场景视图，以及关键陈设与材质的局部特写。'
          '画面中不出现人物，场景结构、陈设、材质、色调与光线氛围保持一致，不添加多余文字。',
    ImageGenerationMethod.product_sheet =>
      '以$source中的产品或道具为准，生成一张产品设定图：纯白背景，'
          '展示正面、侧面、背面与俯视等多角度视图，并配以材质与结构细节特写，'
          '柔和均匀的影棚光。各视图的比例、造型与细节保持一致，不添加任何文字。',
  };
}
