// 职责: Reveric 图标系统 — 封装 phosphor SVG 资产映射与主题感知图标组件。
// 关联文件:
//   pubspec.yaml
//   lib/shared/theme/theme.dart
//   lib/desktop/widgets/sidebar/sidebar.dart
// ignore_for_file: non_constant_identifier_names

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

class RevericIcon extends StatelessWidget {
  const RevericIcon(
    this.assetPath, {
    super.key,
    this.size,
    this.color,
    this.semanticLabel,
  });

  final String assetPath;
  final double? size;
  final Color? color;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final resolvedIconTheme = IconTheme.of(context);
    final resolvedColor = color ?? resolvedIconTheme.color;
    final resolvedSize = size ?? resolvedIconTheme.size ?? 24;
    return SvgPicture.asset(
      assetPath,
      width: resolvedSize,
      height: resolvedSize,
      semanticsLabel: semanticLabel,
      colorFilter: resolvedColor == null
          ? null
          : ColorFilter.mode(resolvedColor, BlendMode.srcIn),
    );
  }
}

class RevericIcons {
  const RevericIcons._();

  static const String _base = 'assets/icons/phosphor';
  static const String _brand = 'assets/icons/brand';

  static const access_time_outlined = '$_base/clock.svg';
  static const account_tree = '$_base/tree-structure.svg';
  static const account_tree_outlined = '$_base/tree-structure.svg';
  static const add = '$_base/plus.svg';
  static const add_box_outlined = '$_base/plus-square.svg';
  static const add_comment_outlined = '$_base/chat-circle.svg';
  static const arrow_square_out = '$_base/arrow-square-out.svg';
  static const add_link = '$_base/link-simple.svg';
  static const add_location = '$_base/map-pin.svg';
  static const add_rounded = '$_base/plus.svg';
  static const alt_route_outlined = '$_base/path.svg';
  static const archive_outlined = '$_base/archive.svg';
  static const attachment = '$_base/paperclip.svg';
  static const arrow_back = '$_base/arrow-left.svg';
  static const arrow_clockwise = '$_base/arrow-clockwise.svg';
  static const arrow_circle_down_outlined = '$_base/arrow-circle-down.svg';
  static const arrow_circle_up_outlined = '$_base/arrow-circle-up.svg';
  static const arrow_counter_clockwise = '$_base/arrow-counter-clockwise.svg';
  static const arrow_downward_rounded = '$_base/arrow-down.svg';
  static const arrow_forward = '$_base/arrow-right.svg';
  static const arrow_forward_rounded = '$_base/arrow-right.svg';
  static const arrow_upward_rounded = '$_base/arrow-up.svg';
  static const aspect_ratio = '$_base/bounding-box.svg';
  static const auto_awesome = '$_base/sparkle.svg';
  static const shuffle_outlined = '$_base/shuffle.svg';
  static const auto_awesome_outlined = '$_base/sparkle.svg';
  static const auto_fix_high_outlined = '$_base/magic-wand.svg';
  static const auto_stories_outlined = '$_base/books.svg';
  static const bar_chart_outlined = '$_base/chart-bar.svg';
  static const battery_full = '$_base/battery-full.svg';
  static const block_outlined = '$_base/prohibit.svg';
  static const block_rounded = '$_base/prohibit.svg';
  static const book = '$_base/book.svg';
  static const book_open = '$_base/book-open.svg';
  static const bookmark_outline = '$_base/bookmark.svg';
  static const brackets_curly = '$_base/brackets-curly.svg';
  static const brightness_auto_outlined = '$_base/circle-half.svg';
  static const bug_beetle_outlined = '$_base/bug-beetle.svg';
  static const broken_image_outlined = '$_base/image-broken.svg';
  static const brush_outlined = '$_base/paint-brush.svg';
  static const build_circle_outlined = '$_base/gear-six.svg';
  static const cancel_rounded = '$_base/x-circle.svg';
  static const caret_right = '$_base/caret-right.svg';
  static const caret_down = '$_base/caret-down.svg';
  static const arrows_in = '$_base/arrows-in.svg';
  static const arrows_out = '$_base/arrows-out.svg';
  static const arrows_horizontal = '$_base/arrows-horizontal.svg';
  static const arrows_vertical = '$_base/arrows-vertical.svg';
  static const arrow_fat_lines_up = '$_base/arrow-fat-lines-up.svg';
  static const aperture = '$_base/aperture.svg';
  static const stack = '$_base/stack.svg';
  static const file_text = '$_base/file-text.svg';
  static const pencil_simple = '$_base/pencil-simple.svg';
  static const category_outlined = '$_base/squares-four.svg';
  static const chat_bubble_outline = '$_base/chat-circle-text.svg';
  static const chat_outlined = '$_base/chat-centered.svg';
  static const arrows_clockwise = '$_base/arrows-clockwise.svg';
  static const cancel_circle = '$_base/x-circle.svg';
  static const clipboard_text = '$_base/clipboard-text.svg';
  static const clock = '$_base/clock.svg';
  static const warning_circle = '$_base/warning-circle.svg';
  static const chat_rounded = '$_base/chat-centered.svg';
  static const chats_circle = '$_base/chats-circle.svg';
  static const check = '$_base/check.svg';
  static const check_box_outline_blank_rounded = '$_base/square.svg';
  static const check_box_rounded = '$_base/check-square.svg';
  static const check_circle = '$_base/check-circle.svg';
  static const check_circle_outline = '$_base/check-circle.svg';
  static const check_circle_rounded = '$_base/check-circle.svg';
  static const check_rounded = '$_base/check.svg';
  static const checklist_rounded = '$_base/list-checks.svg';
  static const chevron_left = '$_base/caret-left.svg';
  static const chevron_right = '$_base/caret-right.svg';
  static const circle_notch = '$_base/circle-notch.svg';
  static const circle_outlined = '$_base/circle.svg';
  static const clear = '$_base/x.svg';
  static const close = '$_base/x.svg';
  static const close_rounded = '$_base/x.svg';
  static const cloud = '$_base/cloud.svg';
  static const cloud_off = '$_base/cloud-slash.svg';
  static const cloud_upload = '$_base/cloud-arrow-up.svg';
  static const coffee_outlined = '$_base/coffee.svg';
  static const copy = '$_base/copy.svg';
  static const copy_outlined = '$_base/copy.svg';
  static const copy_rounded = '$_base/copy.svg';
  static const create_new_folder = '$_base/folder-plus.svg';
  static const create_outlined = '$_base/pencil-line.svg';
  static const crop_square = '$_base/crop.svg';
  static const crop_square_outlined = '$_base/crop.svg';
  static const crop_square_rounded = '$_base/crop.svg';
  static const crown = '$_base/crown.svg';
  static const dark_mode_outlined = '$_base/moon-stars.svg';
  static const delete = '$_base/trash-simple.svg';
  static const delete_outline = '$_base/trash-simple.svg';
  static const description_outlined = '$_base/file-text.svg';
  static const diamond_outlined = '$_base/diamond.svg';
  static const done_all = '$_base/checks.svg';
  static const directions_run_rounded = '$_base/person-simple-run.svg';
  static const download = '$_base/download.svg';
  static const drag_handle = '$_base/dots-six-vertical.svg';
  static const eco_outlined = '$_base/tree.svg';
  static const edit = '$_base/pencil-simple.svg';
  static const edit_note_outlined = '$_base/note-pencil.svg';
  static const edit_note_rounded = '$_base/note-pencil.svg';
  static const edit_outlined = '$_base/pencil-simple.svg';
  static const error_outline = '$_base/warning-circle.svg';
  static const error_outline_rounded = '$_base/warning-circle.svg';
  static const expand_less_rounded = '$_base/caret-up.svg';
  static const expand_more = '$_base/caret-down.svg';
  static const expand_more_rounded = '$_base/caret-down.svg';
  static const explore = '$_base/compass.svg';
  static const family_restroom = '$_base/users.svg';
  static const favorite = '$_base/heart.svg';
  static const fit_screen = '$_base/resize.svg';
  static const flag = '$_base/flag.svg';
  static const frame_corners = '$_base/frame-corners.svg';
  static const folder_outlined = '$_base/folder.svg';
  static const format_bold = '$_base/text-b.svg';
  static const format_italic = '$_base/text-italic.svg';
  static const format_list_bulleted = '$_base/list-bullets.svg';
  static const format_list_numbered = '$_base/list-numbers.svg';
  static const format_quote = '$_base/quotes.svg';
  static const format_h1 = '$_base/text-h-one.svg';
  static const format_h2 = '$_base/text-h-two.svg';
  static const format_h3 = '$_base/text-h-three.svg';
  static const format_h4 = '$_base/text-h-four.svg';
  static const format_h5 = '$_base/text-h-five.svg';
  static const format_h6 = '$_base/text-h-six.svg';
  static const format_heading = '$_base/text-h.svg';
  static const format_strikethrough = '$_base/text-strikethrough.svg';
  static const git_fork = '$_base/git-fork.svg';
  static const grass = '$_base/plant.svg';
  static const group = '$_base/users.svg';
  static const groups_outlined = '$_base/users-three.svg';
  static const groups_rounded = '$_base/users-three.svg';
  static const help_outline = '$_base/question.svg';
  static const help_outline_rounded = '$_base/question.svg';
  static const history_outlined = '$_base/clock-counter-clockwise.svg';
  static const history_rounded = '$_base/clock-counter-clockwise.svg';
  static const home = '$_base/house.svg';
  static const hub_outlined = '$_base/circles-three.svg';
  static const image = '$_base/image.svg';
  static const image_outlined = '$_base/image-square.svg';
  static const inbox_outlined = '$_base/tray.svg';
  static const info_outline = '$_base/info.svg';
  static const inventory_2 = '$_base/package.svg';
  static const inventory_2_outlined = '$_base/package.svg';
  static const keyboard_arrow_down = '$_base/caret-down.svg';
  static const keyboard_arrow_down_rounded = '$_base/caret-down.svg';
  static const keyboard_arrow_left = '$_base/caret-left.svg';
  static const keyboard_arrow_right = '$_base/caret-right.svg';
  static const keyboard_arrow_up = '$_base/caret-up.svg';
  static const label_outline = '$_base/tag.svg';
  static const landscape = '$_base/mountains.svg';
  static const layers_outlined = '$_base/stack.svg';
  static const light_mode_outlined = '$_base/sun-dim.svg';
  static const lightbulb_outline = '$_base/lightbulb.svg';
  static const linear_scale = '$_base/line-segment.svg';
  static const link = '$_base/link.svg';
  static const link_off = '$_base/link-break.svg';
  static const list_alt_outlined = '$_base/list.svg';
  static const location_city = '$_base/city.svg';
  static const location_city_outlined = '$_base/city.svg';
  static const location_on = '$_base/map-pin.svg';
  static const lock_open_outlined = '$_base/lock-open.svg';
  static const lock_outline = '$_base/lock.svg';
  static const lock_simple = '$_base/lock-simple.svg';
  static const map = '$_base/map-trifold.svg';
  static const map_outlined = '$_base/map-trifold.svg';
  static const meeting_room = '$_base/door.svg';
  static const megaphone = '$_base/megaphone.svg';
  static const menu_book_outlined = '$_base/book-open.svg';
  static const menu_book_rounded = '$_base/book-open.svg';
  static const note = '$_base/note.svg';
  static const model_training_outlined = '$_base/brain.svg';
  static const mask_happy_rounded = '$_base/mask-happy.svg';
  static const more_horiz = '$_base/dots-three.svg';
  static const more_horiz_rounded = '$_base/dots-three.svg';
  static const more_vert = '$_base/dots-three-vertical.svg';
  static const movie_outlined = '$_base/film-strip.svg';
  static const near_me_outlined = '$_base/paper-plane.svg';
  static const nightlight_outlined = '$_base/moon.svg';
  static const open_in_full_rounded = '$_base/arrows-out.svg';
  static const close_fullscreen_rounded = '$_base/arrows-in.svg';
  static const outlined_flag = '$_base/flag.svg';
  static const palette_outlined = '$_base/palette.svg';
  static const pan_tool = '$_base/hand.svg';
  static const park = '$_base/tree-evergreen.svg';
  static const pause = '$_base/pause.svg';
  static const pending_actions_rounded = '$_base/clipboard-text.svg';
  static const pending_rounded = '$_base/clock.svg';
  static const people = '$_base/users.svg';
  static const people_alt_outlined = '$_base/users.svg';
  static const person = '$_base/user.svg';
  static const person_outline = '$_base/user.svg';
  static const person_rounded = '$_base/user.svg';
  static const user_circle = '$_base/user-circle.svg';
  static const coins = '$_base/coins.svg';
  static const wechat = '$_base/wechat.svg';
  static const lightning = '$_base/lightning.svg';
  static const cube = '$_base/cube.svg';
  static const receipt = '$_base/receipt.svg';
  static const list_bullets = '$_base/list-bullets.svg';
  static const sign_in = '$_base/sign-in.svg';
  static const sign_out = '$_base/sign-out.svg';
  static const gift = '$_base/gift.svg';
  static const envelope = '$_base/envelope-simple.svg';
  static const lock_key = '$_base/lock-key.svg';
  static const seal_check = '$_base/seal-check.svg';
  static const place = '$_base/map-pin.svg';
  static const place_outlined = '$_base/map-pin.svg';
  static const play_arrow = '$_base/play.svg';
  static const play_arrow_rounded = '$_base/play.svg';
  static const play_circle_outline = '$_base/play-circle.svg';
  static const polyline_outlined = '$_base/vector-three.svg';
  static const psychology_alt_outlined = '$_base/brain.svg';
  static const psychology_outlined = '$_base/brain.svg';
  static const psychology_rounded = '$_base/brain.svg';
  static const public = '$_base/globe.svg';
  static const public_outlined = '$_base/globe.svg';
  static const push_pin = '$_base/push-pin.svg';
  static const push_pin_fill = '$_base/push-pin-fill.svg';
  static const qr_code = '$_base/qr-code.svg';
  static const radio_button_checked_rounded = '$_base/radio-button.svg';
  static const redo = '$_base/arrow-clockwise.svg';
  static const remove = '$_base/minus.svg';
  static const rocket_launch_outlined = '$_base/rocket.svg';
  static const rule_outlined = '$_base/shield.svg';
  static const shield_check = '$_base/shield-check.svg';
  static const sailing = '$_base/boat.svg';
  static const save_outlined = '$_base/floppy-disk.svg';
  static const schedule_outlined = '$_base/clock.svg';
  static const scissors_outlined = '$_base/scissors.svg';
  static const school = '$_base/graduation-cap.svg';
  static const search = '$_base/magnifying-glass.svg';
  static const send_rounded = '$_base/paper-plane.svg';
  static const settings_outlined = '$_base/gear-six.svg';
  static const share_outlined = '$_base/share-network.svg';
  static const smart_toy_outlined = '$_base/robot.svg';
  static const space_dashboard_outlined = '$_base/grid-nine.svg';
  static const star = '$_base/star.svg';
  static const stop_rounded = '$_base/stop.svg';
  // 行内小尺寸停止键用实心字形：regular 权重的空心方框在 20px 下会被读成复选框。
  static const stop_fill = '$_base/stop-fill.svg';
  static const storefront = '$_base/storefront.svg';
  static const summarize_rounded = '$_base/article.svg';
  static const swap_horiz_rounded = '$_base/arrows-left-right.svg';
  static const temple_buddhist_outlined = '$_base/buildings.svg';
  static const terminal_rounded = '$_base/terminal-window.svg';
  static const terrain = '$_base/mountains.svg';
  static const text_fields_outlined = '$_base/text-t.svg';
  static const text_snippet_outlined = '$_base/article.svg';
  static const theater_comedy_outlined = '$_base/film-strip.svg';
  static const theater_comedy_rounded = '$_base/film-strip.svg';
  static const timeline_outlined = '$_base/trend-up.svg';
  static const title = '$_base/text-t.svg';
  static const touch_app = '$_base/cursor-click.svg';
  static const tray_arrow_down = '$_base/tray-arrow-down.svg';
  static const tray_arrow_up = '$_base/tray-arrow-up.svg';
  static const trending_up = '$_base/trend-up.svg';
  static const trending_down = '$_base/trend-down.svg';
  static const tune = '$_base/faders.svg';
  static const undo = '$_base/arrow-counter-clockwise.svg';
  static const upload = '$_base/upload.svg';
  static const upload_outlined = '$_base/upload.svg';
  static const vertical_split_outlined = '$_base/split-horizontal.svg';
  static const visibility = '$_base/eye.svg';
  static const visibility_off = '$_base/eye-slash.svg';
  static const visibility_off_outlined = '$_base/eye-slash.svg';
  static const visibility_outlined = '$_base/eye.svg';
  static const warning = '$_base/warning.svg';
  static const warning_amber_rounded = '$_base/warning.svg';
  static const water = '$_base/waves.svg';
  static const water_drop_outlined = '$_base/drop.svg';
  static const cloud_arrow_up = '$_base/cloud-arrow-up.svg';
  static const download_outlined = '$_base/download.svg';
  static const info = '$_base/info.svg';
  static const system_update_outlined = '$_base/cloud-arrow-up.svg';
  static const ticket = '$_base/ticket.svg';
  static const caret_left = '$_base/caret-left.svg';
  static const cursor = '$_base/cursor.svg';
  static const crosshair_simple = '$_base/crosshair-simple.svg';
  static const skip_back = '$_base/skip-back.svg';
  static const skip_forward = '$_base/skip-forward.svg';
  static const video_camera = '$_base/video-camera.svg';
  static const person_simple_walk = '$_base/person-simple-walk.svg';
  static const waveform = '$_base/waveform.svg';
  static const download_simple = '$_base/download-simple.svg';
  static const flow_arrow = '$_base/flow-arrow.svg';
  static const at = '$_base/at.svg';
  static const magnet = '$_base/magnet.svg';
  static const microphone = '$_base/microphone.svg';
  static const music_notes = '$_base/music-notes.svg';
  static const speaker_high = '$_base/speaker-high.svg';
  static const speaker_slash = '$_base/speaker-slash.svg';
  static const subtitles = '$_base/subtitles.svg';
  static const film_slate = '$_base/film-slate.svg';
  static const clock_clockwise = '$_base/clock-clockwise.svg';
  static const user_focus = '$_base/user-focus.svg';
  static const user_square = '$_base/user-square.svg';
  static const smiley = '$_base/smiley.svg';
  static const calendar_blank = '$_base/calendar-blank.svg';
  static const calendar_dots = '$_base/calendar-dots.svg';
  static const phone = '$_base/phone.svg';
  static const camera = '$_base/camera.svg';
  static const fast_forward = '$_base/fast-forward.svg';
  static const heart_break = '$_base/heart-break.svg';
  static const bell = '$_base/bell.svg';
  static const bell_slash = '$_base/bell-slash.svg';
  static const credit_card = '$_base/credit-card.svg';
  static const printer = '$_base/printer.svg';
  static const rewind = '$_base/rewind.svg';
  static const shopping_cart = '$_base/shopping-cart.svg';
  static const star_half = '$_base/star-half.svg';
  static const speaker_low = '$_base/speaker-low.svg';
  static const speaker_none = '$_base/speaker-none.svg';
  static const github_logo = '$_base/github-logo.svg';

  /// QQ 品牌标（Simple Icons, CC0），实心图形。
  static const qq_logo = '$_brand/qq.svg';
}
