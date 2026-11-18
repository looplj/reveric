# 本地媒体加工

FFmpeg 负责素材加工与检查；组织镜头、音轨和字幕来剪辑成片使用 editing。拼接、混音、叠加可以用于制作中间素材，产物需要显式加入或替换到工程中。

先确定输入文件与所需变换。熟悉的抽帧、缩放、裁剪、转码等常规操作按本附件的参数与文件边界直接执行；查看画面优先使用 frames，读取规格使用 probe。首次使用不需要预读 capabilities。

仅在不确定组件参数、需要确认本机支持情况，或实际错误指向编码器／滤镜缺失及参数不支持时查询 capabilities。参数疑问用 component 查询目标组件帮助；需要核对引擎能力或应用允许范围时，在 Codemode 内读取能力清单并筛选，只输出目标组件是否存在、是否允许及相关限制，保留查询失败的错误信息。

usable_filters 是当前引擎已提供且入口允许的滤镜；其他能力结合原生清单与 allowed_filters、allowed_formats、allowed_flags、allowed_value_options、allowed_output_extensions 判断，具体格式还须满足输入解封装器和输出扩展名限制。组件帮助描述原生参数，不代表应用已开放所有参数或外部 IO。

## 命令参数

调用格式为 `{"command":"ffmpeg","subcommand":"操作名","options":{...}}`。

| subcommand | 必填 options | 可选 options 与行为 |
|---|---|---|
| `capabilities` | 无 | 按需传 component 查询组件帮助，如 encoder=libx264、filter=loudnorm、demuxer=image2；空 options 返回完整能力清单，筛选后再输出所需信息 |
| `probe` | `args` | 只检查一个输入文件 |
| `frames` | `path`、`timestamps_ms` | 返回带时间标注的画面拼图 |
| `execute` | `args` | 加工显式输入并生成新输出文件 |

检查文件规格：

```json
{"command":"ffmpeg","subcommand":"probe","options":{"args":["-show_format","-show_streams","-of","json","{file_path}"]}}
```

检查多个时间位置的画面，优先使用 frames：

```json
{"command":"ffmpeg","subcommand":"frames","options":{"path":"{file_path}","timestamps_ms":[0,1000,3000]}}
```

`path` 是待提帧的输入视频路径，输出位置由系统管理。timestamps_ms 是从视频开始计算的毫秒位置，必须包含 1..16 个非负整数，且严格小于视频时长；顺序与重复位置原样保留。提取指定位置处或之后的首个可解码画面，不用平均帧率换算帧号。位置处没有画面时返回错误，不静默改取末帧。只接受本地视频；无视频轨或无法确定正时长时拒绝。

成功结果包含 file_path、width、height、cells 和可直接查看的图片 content；cells 按请求顺序记录 label 与 timestamp_ms（请求位置）。单取一个时间点时保留源画面细节，最长边超过 2048 像素才缩小。16 帧按 4×4 排列，拼图最长边不超过 2048 像素，保存为会话 JPEG，无需自定输出名称，也不修改原视频。拼图随会话文件管理，不使用 editing cleanup 删除。

从视频第 1 秒提取一帧并保存为独立 PNG 文件：

```json
{"command":"ffmpeg","subcommand":"execute","options":{"args":["-ss","1","-i","{file_path}","-frames:v","1","frame-001.png"]}}
```

args 是逐项字符串数组，不含 ffmpeg / ffprobe 程序名，不是 shell 命令；不把整条命令塞进一个字符串。execute 支持最多 32 个输入和 16 个不同输出规格（单文件、图片序列或视频分段）；probe 只接受一个文件。参数总数最多 4096、总文本最多 256 KiB。输入序列、concat 清单、滤镜资源和附件会展开成实际文件进行读取检查，最多 4096 个文件。

输入和输出的相对路径以当前作品文件目录为根，例如 `videos/input.mp4`、`files/captions.srt`；裸文件名也从作品根解析。本作品相对输入免审批，绝对输入及作品外依赖需要读取授权，显式绝对路径即使指向本作品也走审批。

输出必须是本作品内的新文件，只接受相对路径；不能使用绝对输出路径、覆盖已有文件或把输出指向输入。序列、分段和两遍编码日志也遵循相同写入边界，读取授权不允许写入其他作品或共享目录。不支持网络拉流/推流、设备采集、shell、glob 通配符、HLS/DASH 发布及任意脚本加载。编号模板见下文；普通文件名中的百分号允许使用。参数被拒绝时按实际支持范围修正，不绕过约束。

## 素材加工与检测

支持常用的视频降噪、锐化、模糊、抠像、调色、淡入淡出、推拉、调色板，以及音频降噪、响度归一、均衡、压缩、限幅、声道和静音检测。原生编码器未编译进运行库时会失败，不通过换命令宣称处理成功。

编码参数支持流选择符，例如 -c:v:0、-b:a:1、-profile:v、-disposition:a:0、-metadata:s:a:0；支持负向 -map、多音轨、章节映射、色彩元数据及常用 bitstream filter。-x264-params / -x265-params 仅接受已支持的纯处理选项，不允许额外指定日志或统计文件路径。

处理原始像素或 PCM 时显式给出 -f、尺寸/像素格式或采样率/声道等解释参数。需要媒体规格时调用 probe。

用 probe 的 -show_frames、-show_packets、-show_chapters、-count_packets、-read_intervals、-show_entries 检查局部媒体信息。输出为 JSON，最多 4 MiB；大文件按区间和字段缩小结果，避免全量列出每个包。

只做检测时用 -f null -，检测信息在 log；日志过长时只返回末尾部分，检查 log_truncated。检测不限于是否生成文件，必须读取实际检测结论。

```json
{"command":"ffmpeg","subcommand":"execute","options":{"args":["-i","{file_path}","-vn","-af","volumedetect","-f","null","-"]}}
```

execute 必须提供已有文件、图片序列或 concat 清单作为输入。不支持 lavfi 输入，以及 color、anullsrc、testsrc、sine 等源滤镜；不能通过 filter_complex 绕过。loop、aloop 滤镜及 -loop、-stream_loop 参数也不开放。成片的背景与静音底轨由 editing 工程渲染处理。

## 输入依赖

图片序列输入使用 %d 或 %0Nd（N 为 1..9），可用 -framerate 与 -start_number。编号必须连续；省略起始编号时在 0..4 中找首张，其他起始编号必须明确指定。不会因缺图而默默截短输入。

```json
{"command":"ffmpeg","subcommand":"execute","options":{"args":["-framerate","24","-start_number","1","-i","images/frame-%03d.png","-c:v","libx264","-pix_fmt","yuv420p","sequence.mp4"]}}
```

concat 列表通过 -f concat -i list.txt 输入。绝对路径或不符合 FFmpeg 安全文件名规则的条目需要显式指定 -safe 0。清单只支持 file、duration、inpoint、outpoint；file 相对路径按清单所在目录解析。清单内不接受网络、嵌套播放列表或自定义 option 指令。所有文件都必须可读取；同规格无损拼接可用 -c copy，需要滤镜变换时使用 concat 滤镜。

字幕烧录使用 subtitles / ass 的 filename（或 f），文字水印使用 drawtext 的 text、textfile、fontfile；LUT 使用 lut3d / lut1d 的 file，曲线文件使用 curves 的 psfile。drawtext 省略 fontfile 时自动使用应用内置的中文字体（霞鹜文楷），中英文都能显示，不要猜测系统字体路径；确需其他字体时，fontfile 只填已确认存在的文件。依赖的相对路径从当前作品文件目录解析，不相对视频目录猜测；字体、字幕、附件、序列和 concat 子文件都计入读取授权，清单中新发现的作品外文件可能需要再次审批。不支持 fontsdir 目录加载及 curves 的 plot 文件输出。滤镜仍使用 FFmpeg 自身的两层转义语法：JSON 字符串转义之外，冒号、引号、反斜杠等还需按滤镜语法转义，Windows 盘符尤其如此。

```json
{"command":"ffmpeg","subcommand":"execute","options":{"args":["-i","{file_path}","-vf","subtitles=filename=files/captions.srt","-c:v","libx264","captioned.mp4"]}}
```

字幕文件可作为 -i 输入进行格式转换或封装。-attach 将指定文件附加到支持的容器；-dump_attachment:t:0 指定一个明确的新输出文件名来提取附件，不接受空名称或编号模板。

## 分段、两遍编码与硬件

视频或音频分段使用 -f segment、-segment_time / -segment_times / -segment_frames 和带编号的输出名，默认从 0 编号，可用 -segment_start_number 调整。一次最多 256 段，直接写入指定目录；分段位置受关键帧影响，不能把 -c copy 分段当作精确逐帧剪切。暂不生成额外 segment_list。

```json
{"command":"ffmpeg","subcommand":"execute","options":{"args":["-i","{file_path}","-c","copy","-f","segment","-segment_time","10","-reset_timestamps","1","videos/part-%03d.mp4"]}}
```

两遍编码须分别提交 -pass 1 和 -pass 2，每次调用只执行指定的一遍。使用 -c:v libx264、目标 -b:v，两个调用使用同一个 -passlogfile 作品内相对路径前缀；省略时默认使用作品根下的 ffmpeg2pass。统计文件保留供下一遍读取。每遍只支持一个普通输出或 -f null -；其他编码器的两遍流程不在当前契约内。

硬件能力随平台、编译选项和设备而异。选用尚未核实的硬件加速时，核对 hardware_acceleration 和目标编码器是否可用；参数不确定时再查具体 encoder 帮助。支持 -hwaccel、-hwaccel_device、-hwaccel_output_format、-init_hw_device、-filter_hw_device 及相应硬件滤镜。设备参数使用设备序号或名称，不传任意文件系统路径；失败时报告实际结果，不静默切换软件编码。

每次 execute 最多 30 分钟，probe 最多 30 秒。支持后台等待、进度与取消，输出数量上限由运行时监测，超出上限会取消执行并报告应用侧的限制原因，保留已写出的文件和原生退出码、日志。

## 批量图片序列

批量生成独立图片使用 execute 的序列输出；少量画面检查及带标签拼图仍优先使用 frames。

每秒抽取一张 JPEG，最多 12 张，从 1 开始编号：

```json
{"command":"ffmpeg","subcommand":"execute","options":{"args":["-i","{file_path}","-vf","fps=1","-q:v","2","-frames:v","12","frame-%03d.jpg"]}}
```

- 输出文件名支持一个 `%d` 或 `%0Nd`（N 为 1..9），如 frame-%03d.jpg；占位符不能放在目录中。格式支持 PNG、JPEG、WebP；省略 -f 时自动使用 image2，显式指定时也必须是 image2。
- 每个序列输出前必须单独提供 `-frames:v N`；N 为正整数，同次调用的所有序列合计最多 240 张。实际生成数量取决于输入内容和命令参数。
- `-start_number` 设置该序列起始编号，默认 1，可以从 0 开始；其作用域到紧随其后的输出，不沿用到下一个输出。序列可与普通文件输出混用。
- `-q:v` 必须是有限数值，具体取值范围和效果由编码器决定；入口不统一限制为 0..31。`-fps_mode` 支持 passthrough、cfr、vfr、auto、drop；drop 已被 FFmpeg 弃用，不建议用于新命令。按条件抽取已有帧可用 select + passthrough，按频率采样可用 fps；拼图可用 tile。
- 请求范围内展开后的目标文件名不得重复、覆盖已有文件或指向输入。出现冲突时更换输出名称；不要添加 -y 绕过。

例如每隔 24 帧取一张，从 100 开始编号：

```json
{"command":"ffmpeg","subcommand":"execute","options":{"args":["-i","{file_path}","-vf","select='not(mod(n,24))'","-fps_mode","passthrough","-frames:v","8","-start_number","100","frame-%03d.png"]}}
```

execute 的命令执行结果包含 exit_code、log、log_truncated 与 status；ok 表示执行成功。status 区分 completed、failed、cancelled、timed_out、start_failed、execution_failed 和 resource_limit。没有取得原生退出码时 exit_code 为 null。应用侧启动、结果读取或资源限制错误另有 error_code 和 error；FFmpeg 自身的失败原因读取 log。

输出路径由 args 指定。读取文本用 files read-text，查看图片用 files view-image，检查音视频规格用 files read-video-metadata / read-audio-metadata 或 probe，观察视频画面用 frames。

失败、取消、超时或资源限额中断时，已经写出的文件保留在原位置。依据状态和日志决定下一步，不把留下的文件当作成功结果；重试仍需遵守不得覆盖已有文件的约束。

execute 等待终态后，依据退出码、状态和日志报告执行结果。用户要求检查内容时再显式读取或提帧；不能仅凭执行成功声称看过视频或验证了整段内容。FFmpeg 结果不会自动成为片段采用结果或更新剪辑工程，需要回到相应业务显式使用。
