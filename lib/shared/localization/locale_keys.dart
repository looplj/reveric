// 职责: 多语言 key 常量定义 — 为界面与默认文案提供统一的翻译键。
// 关联文件:
//   assets/translations/en/*.json
//   assets/translations/zh-CN/*.json
//   lib/shared/localization/app_localization.dart
//   lib/shared/localization/merging_asset_loader.dart
//
// Agent 使用说明（本文件 4441 个常量，按 namespace 分区，不要整读）：
// - 分区依据是常量 value 的首段（如 `ai.tool_name_read` 属于 ai 区），每个分区以
//   `// ── <namespace>` 横幅开头，与 assets/translations/<lang>/ 下的 JSON 文件一一对应。
// - 定位方法：先确定文案所属 namespace（通常是目标文案所在页面的翻译 JSON 文件名），
//   再 Grep `── <namespace>` 跳到分区；要列出该区全部 key 时 Grep `= '<namespace>.`。
// - 命名规律：常量名 = value 去掉 namespace 后按点转驼峰，如
//   `ai.tool_name_read` → `aiToolNameRead`、`workspace.novel_description` → `workspaceNovelDescription`。
//   反查某个 key 是否已存在时，优先 Grep value 的片段，不要猜常量名。
// - 新增或修改 key 必须同步 en 与 zh-CN 两份 JSON，规则见 .agents/rules/i18n.md。
abstract final class LocaleKeys {
  static const directorFrameUnavailable = 'director.frame_unavailable';
  static const directorRecoveryFields = 'director.recovery_fields';
  static const directorParallelReferenceUp = 'director.parallel_reference_up';
  static const directorOutOfRange = 'director.out_of_range';
  static const directorZeroDirection = 'director.zero_direction';
  static const directorLighting = 'director.lighting';
  static const directorAmbientIntensity = 'director.lighting.ambient_intensity';
  static const directorKeyIntensity = 'director.lighting.key_intensity';
  static const directorKeyDirection = 'director.lighting.key_direction';
  static const directorPoseParamRightKneeBend =
      'director.pose_param_right_knee_bend';
  static const directorPoseParamRightHipTwist =
      'director.pose_param_right_hip_twist';
  static const directorPoseParamRightHipAbduct =
      'director.pose_param_right_hip_abduct';
  static const directorPoseParamRightHipRaise =
      'director.pose_param_right_hip_raise';
  static const directorPoseParamRightElbowBend =
      'director.pose_param_right_elbow_bend';
  static const directorPoseParamRightShoulderTwist =
      'director.pose_param_right_shoulder_twist';
  static const directorPoseParamRightShoulderAbduct =
      'director.pose_param_right_shoulder_abduct';
  static const directorPoseParamRightShoulderRaise =
      'director.pose_param_right_shoulder_raise';
  static const directorPoseParamLeftKneeBend =
      'director.pose_param_left_knee_bend';
  static const directorPoseParamLeftHipTwist =
      'director.pose_param_left_hip_twist';
  static const directorPoseParamLeftHipAbduct =
      'director.pose_param_left_hip_abduct';
  static const directorPoseParamLeftHipRaise =
      'director.pose_param_left_hip_raise';
  static const directorPoseParamLeftElbowBend =
      'director.pose_param_left_elbow_bend';
  static const directorPoseParamLeftShoulderTwist =
      'director.pose_param_left_shoulder_twist';
  static const directorPoseParamLeftShoulderAbduct =
      'director.pose_param_left_shoulder_abduct';
  static const directorPoseParamLeftShoulderRaise =
      'director.pose_param_left_shoulder_raise';
  static const directorPoseParamRootOffsetY =
      'director.pose_param_root_offset_y';
  static const directorPoseParamHeadRoll = 'director.pose_param_head_roll';
  static const directorPoseParamHeadYaw = 'director.pose_param_head_yaw';
  static const directorPoseParamHeadPitch = 'director.pose_param_head_pitch';
  static const directorPoseParamTorsoRoll = 'director.pose_param_torso_roll';
  static const directorPoseParamTorsoYaw = 'director.pose_param_torso_yaw';
  static const directorPoseParamTorsoPitch = 'director.pose_param_torso_pitch';
  static const directorPoseParamBodyRoll = 'director.pose_param_body_roll';
  static const directorPoseParamBodyYaw = 'director.pose_param_body_yaw';
  static const directorPoseParamBodyPitch = 'director.pose_param_body_pitch';
  static const directorModeAnimationConflict =
      'director.mode_animation_conflict';
  static const directorPathReplace = 'director.path_replace';
  static const directorPathHint = 'director.path_hint';
  static const directorPathFinish = 'director.path_finish';
  static const directorPathSmooth = 'director.path_smooth';
  static const directorPathPlane = 'director.path_plane';
  static const directorPathStartCorner = 'director.path_start_corner';
  static const directorPathStartAngle = 'director.path_start_angle';
  static const directorPathDepth = 'director.path_depth';
  static const directorPathWidth = 'director.path_width';
  static const directorPathRadius = 'director.path_radius';
  static const directorPathCenter = 'director.path_center';
  static const directorPathHeight = 'director.path_height';
  static const directorPathEdit = 'director.path_edit';
  static const directorPathDraw = 'director.path_draw';
  static const directorPathClockwise = 'director.path_clockwise';
  static const directorPathClosed = 'director.path_closed';
  static const directorPathOrient = 'director.path_orient';
  static const directorSetDefault = 'director.set_default';
  static const directorAddCut = 'director.add_cut';
  static const directorCameraCuts = 'director.camera_cuts';
  static const directorFixed = 'director.fixed';
  static const directorSequence = 'director.sequence';
  static const directorFar = 'director.far';
  static const directorNear = 'director.near';
  static const directorSensorHeightMm = 'director.sensor_height_mm';
  static const directorReferenceUp = 'director.reference_up';
  static const directorRoll = 'director.roll';
  static const directorBone = 'director.bone';
  static const directorOffset = 'director.offset';
  static const directorTargetBone = 'director.target_bone';
  static const directorTargetObject = 'director.target_object';
  static const directorTargetPoint = 'director.target_point';
  static const directorCameraTarget = 'director.camera_target';
  static const directorFree = 'director.free';
  static const directorOrientationMode = 'director.orientation_mode';
  static const directorPathPen = 'director.path_pen';
  static const directorPathPencil = 'director.path_pencil';
  static const directorPathRectangle = 'director.path_rectangle';
  static const directorPathCircle = 'director.path_circle';
  static const directorPathEasing = 'director.path_easing';
  static const directorPosePresets = 'director.pose_presets';
  static const directorPoseAdjust = 'director.pose_adjust';
  static const directorPoseGroupBody = 'director.pose_group_body';
  static const directorPoseGroupTorso = 'director.pose_group_torso';
  static const directorPoseGroupHead = 'director.pose_group_head';
  static const directorPoseGroupLeftArm = 'director.pose_group_left_arm';
  static const directorPoseGroupRightArm = 'director.pose_group_right_arm';
  static const directorPoseGroupLeftLeg = 'director.pose_group_left_leg';
  static const directorPoseGroupRightLeg = 'director.pose_group_right_leg';
  static const directorPoseShortLean = 'director.pose_short_lean';
  static const directorPoseShortTurn = 'director.pose_short_turn';
  static const directorPoseShortTilt = 'director.pose_short_tilt';
  static const directorPoseShortTwist = 'director.pose_short_twist';
  static const directorPoseShortNod = 'director.pose_short_nod';
  static const directorPoseShortLook = 'director.pose_short_look';
  static const directorPoseShortRaise = 'director.pose_short_raise';
  static const directorPoseShortAbduct = 'director.pose_short_abduct';
  static const directorPoseShortBend = 'director.pose_short_bend';
  static const directorPoseShortLift = 'director.pose_short_lift';
  static const directorPoseShortHeight = 'director.pose_short_height';
  static const directorPathInHandle = 'director.path_in_handle';
  static const directorPathOutHandle = 'director.path_out_handle';
  static const directorPathAddHandles = 'director.path_add_handles';
  static const directorPathAddPoint = 'director.path_add_point';
  static const directorPathLine = 'director.path_line';
  static const directorBake = 'director.bake';
  static const directorVisible = 'director.visible';
  static const directorControlledChannel = 'director.controlled_channel';
  static const directorAddKeyFirst = 'director.add_key_first';
  static const directorOpenTimeline = 'director.open_timeline';
  static const directorShowTimeline = 'director.show_timeline';
  static const directorAutoKey = 'director.auto_key';
  static const aiPermissionFileDisclosure = 'ai.permission_file_disclosure';
  static const aiPermissionsTitle = 'ai.permissions_title';
  static const aiPermissionAllow = 'ai.permission_allow';
  static const aiPermissionAsk = 'ai.permission_ask';
  static const aiPermissionDeny = 'ai.permission_deny';
  static const aiPermissionInherit = 'ai.permission_inherit';
  static const aiPermissionOnce = 'ai.permission_once';
  static const aiPermissionGlobal = 'ai.permission_global';
  static const aiPermissionWork = 'ai.permission_work';
  static const aiPermissionEpisode = 'ai.permission_episode';
  static const aiPermissionSession = 'ai.permission_session';
  static const aiPermissionScope = 'ai.permission_scope';
  static const aiPermissionDefault = 'ai.permission_default';
  static const aiPermissionSaveFailed = 'ai.permission_save_failed';
  static const aiPermissionLoadFailed = 'ai.permission_load_failed';
  static const aiPermissionLoading = 'ai.permission_loading';
  static const aiPermissionGenerationImage = 'ai.permission_generation_image';
  static const aiPermissionGenerationVideo = 'ai.permission_generation_video';
  static const aiPermissionGenerationAudio = 'ai.permission_generation_audio';
  static const aiPermissionFilesRead = 'ai.permission_files_read';
  static const aiPermissionFilesRemove = 'ai.permission_files_remove';
  static const aiToolRunFilesList = 'ai.tool_run_files_list';
  static const aiToolRunFilesReadText = 'ai.tool_run_files_read_text';
  static const aiToolRunViewImage = 'ai.tool_run_view_image';
  static const aiToolRunFilesReadVideoMetadata =
      'ai.tool_run_files_read_video_metadata';
  static const aiToolRunFilesReadAudioMetadata =
      'ai.tool_run_files_read_audio_metadata';
  static const aiToolRunEditingList = 'ai.tool_run_editing_list';
  static const aiToolRunEditingRead = 'ai.tool_run_editing_read';
  static const aiToolRunEditingApply = 'ai.tool_run_editing_apply';
  static const aiToolRunEditingPreview = 'ai.tool_run_editing_preview';
  static const aiToolRunEditingExport = 'ai.tool_run_editing_export';
  static const aiToolRunOperationsList = 'ai.tool_run_operations_list';
  static const aiToolRunOperationsRead = 'ai.tool_run_operations_read';
  static const aiToolRunOperationsWait = 'ai.tool_run_operations_wait';
  static const aiToolRunFfmpegCapabilities = 'ai.tool_run_ffmpeg_capabilities';
  static const aiToolRunFfmpegProbe = 'ai.tool_run_ffmpeg_probe';
  static const aiToolRunProductionCapturePanorama =
      'ai.tool_run_production_capture_panorama';
  static const aiToolRunProductionDeriveView =
      'ai.tool_run_production_derive_view';
  static const aiToolRunProductionImagePreset =
      'ai.tool_run_production_image_preset';
  static const aiToolRunFfmpegFrames = 'ai.tool_run_ffmpeg_frames';
  static const aiToolRunFfmpegExecute = 'ai.tool_run_ffmpeg_execute';
  static const aiOperationFileUnavailable = 'ai.operation_file_unavailable';
  static const aiOperationFailedHint = 'ai.operation_failed_hint';
  static const aiOperationWaitingApproval = 'ai.operation_waiting_approval';
  static const aiOperationQueued = 'ai.operation_queued';
  static const aiOperationRunning = 'ai.operation_running';
  static const aiOperationCancelling = 'ai.operation_cancelling';
  static const aiOperationCompleted = 'ai.operation_completed';
  static const aiOperationFailed = 'ai.operation_failed';
  static const aiOperationCancelled = 'ai.operation_cancelled';
  static const aiOperationInterrupted = 'ai.operation_interrupted';
  static const aiOperationCancelTimeout = 'ai.operation_cancel_timeout';
  static const aiPermissionScopeAlways = 'ai.permission_scope_always';
  static const aiPermissionEffectiveColumn = 'ai.permission_effective_column';
  static const aiPermissionDenied = 'ai.permission_denied';
  static const aiOperationConflict = 'ai.operation_conflict';
  static const aiOperationStripTitle = 'ai.operation_strip_title';
  static const aiOperationStripSettled = 'ai.operation_strip_settled';
  static const aiOperationWaitingCount = 'ai.operation_waiting_count';
  static const aiApprovalFactModel = 'ai.approval_fact_model';
  static const aiApprovalFactRatio = 'ai.approval_fact_ratio';
  static const aiApprovalFactSize = 'ai.approval_fact_size';
  static const aiApprovalFactDuration = 'ai.approval_fact_duration';
  static const aiApprovalFactReferences = 'ai.approval_fact_references';
  static const aiApprovalFactPrompt = 'ai.approval_fact_prompt';
  static const aiApprovalFactPath = 'ai.approval_fact_path';
  static const aiApprovalFactInputFileCount =
      'ai.approval_fact_input_file_count';
  static const aiApprovalFactInputDirectoryCount =
      'ai.approval_fact_input_directory_count';
  static const aiApprovalFactInputDirectories =
      'ai.approval_fact_input_directories';
  static const aiApprovalFactInputDirectoriesPreview =
      'ai.approval_fact_input_directories_preview';
  static const aiApprovalDetails = 'ai.approval_details';
  static const aiApprovalFactMatchedCount = 'ai.approval_fact_matched_count';
  static const aiApprovalFactRecursive = 'ai.approval_fact_recursive';
  static const aiApprovalFactFolders = 'ai.approval_fact_folders';
  static const aiApprovalFactFolderCount = 'ai.approval_fact_folder_count';
  static const aiApprovalFactArgs = 'ai.approval_fact_args';
  static const aiApprovalItemCount = 'ai.approval_item_count';
  static const aiApprovalFactMode = 'ai.approval_fact_mode';
  static const productionReferenceStorageNotConnected =
      'production.reference_storage_not_connected';
  static const productionStorageRequiredTitle =
      'production.storage_required_title';
  static const productionStorageRequiredMessage =
      'production.storage_required_message';
  static const productionToSegments = 'screenplay.production.toSegments';
  static const productionInsertShot = 'screenplay.production.insertShot';
  static const productionAiNew = 'screenplay.production.aiNew';
  static const productionAiEdited = 'screenplay.production.aiEdited';
  static const productionSplit = 'screenplay.production.split';
  static const productionReorder = 'screenplay.production.reorder';
  static const productionSeconds = 'screenplay.production.seconds';
  static const productionSceneStat = 'screenplay.production.sceneStat';
  static const productionSceneMissingDuration =
      'screenplay.production.sceneMissingDuration';
  static const productionSceneEmpty = 'screenplay.production.sceneEmpty';
  static const productionStatusPlanned = 'screenplay.production.statusPlanned';
  static const productionStatusCount = 'screenplay.production.statusCount';
  static const productionStatusDone = 'screenplay.production.statusDone';
  static const productionExportSegment = 'screenplay.production.exportSegment';
  static const productionExportClipsMeta =
      'screenplay.production.exportClipsMeta';
  static const productionNoPrompt = 'screenplay.production.noPrompt';
  static const productionVideoTag = 'screenplay.production.videoTag';
  static const productionResults = 'screenplay.production.results';
  static const productionPreviewAdopted =
      'screenplay.production.previewAdopted';
  static const productionAssets = 'screenplay.production.assets';
  static const productionAddToLibrary = 'screenplay.production.add_to_library';
  static const productionRemoveFromLibrary =
      'screenplay.production.remove_from_library';
  static const commonUpload = 'common.upload';
  static const commonView = 'common.view';
  static const productionCharacter = 'screenplay.production.character';
  static const productionLocation = 'screenplay.production.location';
  static const productionAddCompendiumHint =
      'screenplay.production.addCompendiumHint';
  static const productionAddCharacterHint =
      'screenplay.production.addCharacterHint';
  static const productionAddLocationHint =
      'screenplay.production.addLocationHint';
  static const productionSpeechVoiceRequired =
      'screenplay.production.speechVoiceRequired';
  static const productionSpeechText = 'screenplay.production.speechText';
  static const productionSpeechCustomVoice =
      'screenplay.production.speechCustomVoice';
  static const productionSpeechVoiceId = 'screenplay.production.speechVoiceId';
  static const productionSpeechVoiceIdHint =
      'screenplay.production.speechVoiceIdHint';
  static const productionSpeechInstructions =
      'screenplay.production.speechInstructions';
  static const productionSpeechInstructionsHint =
      'screenplay.production.speechInstructionsHint';
  static const productionSpeechUsingReference =
      'screenplay.production.speechUsingReference';
  static const productionBuiltinVoices = 'screenplay.production.builtinVoices';
  static const productionVoiceWarmFemale =
      'screenplay.production.voiceWarmFemale';
  static const productionVoiceCoolFemale =
      'screenplay.production.voiceCoolFemale';
  static const productionVoiceBrightGirl =
      'screenplay.production.voiceBrightGirl';
  static const productionVoiceClearBoy = 'screenplay.production.voiceClearBoy';
  static const productionVoiceWarmMale = 'screenplay.production.voiceWarmMale';
  static const productionVoiceDeepMale = 'screenplay.production.voiceDeepMale';
  static const productionVoiceWeatheredElder =
      'screenplay.production.voiceWeatheredElder';
  static const productionVoices = 'screenplay.production.voices';
  static const productionVoicesManage = 'screenplay.production.voicesManage';
  static const productionVoicesHint = 'screenplay.production.voicesHint';
  static const productionVoicesEmpty = 'screenplay.production.voicesEmpty';
  static const productionVoiceMode = 'screenplay.production.voiceMode';
  static const productionSubjectProfile =
      'screenplay.production.subjectProfile';
  static const productionPhotosEmpty = 'screenplay.production.photosEmpty';
  static const productionMediaUnavailable =
      'screenplay.production.mediaUnavailable';
  static const productionFileMissing = 'screenplay.production.fileMissing';
  static const productionImage = 'screenplay.production.image';
  static const productionList = 'screenplay.production.list';
  static const productionImageInterrupted =
      'screenplay.production.imageInterrupted';
  static const productionImageDownloadFailed =
      'screenplay.production.imageDownloadFailed';
  static const productionImageFetchFailed =
      'screenplay.production.imageFetchFailed';
  static const productionCameraLibrary = 'screenplay.production.cameraLibrary';
  static const productionImportHint = 'screenplay.production.importHint';
  static const productionAddNode = 'screenplay.production.addNode';
  static const productionAddSegment = 'screenplay.production.addSegment';
  static const productionAddSegmentHint =
      'screenplay.production.addSegmentHint';
  static const productionAddVideoHint = 'screenplay.production.addVideoHint';
  static const productionAddImageHint = 'screenplay.production.addImageHint';
  static const productionAddAudioHint = 'screenplay.production.addAudioHint';
  static const productionAddDirectorHint =
      'screenplay.production.addDirectorHint';
  static const productionOpenDirector = 'screenplay.production.openDirector';
  static const productionDirectorStill = 'screenplay.production.directorStill';
  static const productionDirectorMotion =
      'screenplay.production.directorMotion';
  static const productionDirectorName = 'screenplay.production.directorName';
  static const productionDirectorOutputs =
      'screenplay.production.directorOutputs';
  static const productionExportStill = 'screenplay.production.exportStill';
  static const productionExportMotion = 'screenplay.production.exportMotion';
  static const productionVideoTools = 'screenplay.production.videoTools';
  static const productionMute = 'screenplay.production.mute';
  static const productionTrim = 'screenplay.production.trim';
  static const productionDepthCapture = 'screenplay.production.depth.title';
  static const productionDepthPrepare = 'screenplay.production.depth.prepare';
  static const productionDepthStart = 'screenplay.production.depth.start';
  static const productionDepthBackground =
      'screenplay.production.depth.background';
  static const productionDepthLibraryOnly =
      'screenplay.production.depth.libraryOnly';
  static const productionDepthNoTask = 'screenplay.production.depth.noTask';
  static const productionDepthError = 'screenplay.production.depth.error';
  static const productionTrimRange = 'screenplay.production.trimRange';
  static const productionSeparateAudio = 'screenplay.production.separateAudio';
  static const productionCaptureFrame = 'screenplay.production.captureFrame';
  static const productionCaptureCurrent =
      'screenplay.production.captureCurrent';
  static const productionCaptureCurrentHint =
      'screenplay.production.captureCurrentHint';
  static const productionCaptureFirst = 'screenplay.production.captureFirst';
  static const productionCaptureLast = 'screenplay.production.captureLast';
  static const productionVideoNoAudio = 'screenplay.production.videoNoAudio';
  static const productionUnlink = 'screenplay.production.unlink';
  static const productionUnlinkHint = 'screenplay.production.unlinkHint';
  static const productionReference = 'screenplay.production.reference';

  static const productionExportIncomplete =
      'screenplay.production.exportIncomplete';
  static const productionExportMissing = 'screenplay.production.exportMissing';

  static const productionTitle = 'screenplay.production.title';
  static const productionCanvas = 'screenplay.production.canvas';
  static const productionDeleteNodeConfirm =
      'screenplay.production.deleteNodeConfirm';
  static const productionIndependentMedia =
      'screenplay.production.independentMedia';
  static const productionFreeVideo = 'screenplay.production.freeVideo';
  static const productionAddInput = 'screenplay.production.addInput';
  static const productionGenerateBusy = 'screenplay.production.generateBusy';
  static const productionGenerateChecking =
      'screenplay.production.generateChecking';
  static const productionGenerateModelRequired =
      'screenplay.production.generateModelRequired';
  static const productionGenerateProviderRequired =
      'screenplay.production.generateProviderRequired';
  static const productionGenerateReferenceMissing =
      'screenplay.production.generateReferenceMissing';
  static const productionGenerateFramesRequired =
      'screenplay.production.generateFramesRequired';
  static const productionGenerateVisualReferenceRequired =
      'screenplay.production.generateVisualReferenceRequired';
  static const productionGenerateTooManyAudio =
      'screenplay.production.generateTooManyAudio';
  static const productionGenerateAudioInputs =
      'screenplay.production.generateAudioInputs';
  static const productionGenerateVoiceInputs =
      'screenplay.production.generateVoiceInputs';
  static const productionGenerateTooManyInputs =
      'screenplay.production.generateTooManyInputs';
  static const productionGenerateInvalidField =
      'screenplay.production.generateInvalidField';
  static const productionMoveScene = 'screenplay.production.moveScene';
  static const productionTidyCanvas = 'screenplay.production.tidyCanvas';
  static const productionGenerate = 'screenplay.production.generate';
  static const productionGenerateDraft = 'screenplay.production.generateDraft';
  static const productionDraftHint = 'screenplay.production.draftHint';
  static const productionDraftLabel = 'screenplay.production.draftLabel';
  static const productionCompleteDraft = 'screenplay.production.completeDraft';
  static const productionDraftCompletionHint =
      'screenplay.production.draftCompletionHint';
  static const productionDraftCompletionPending =
      'screenplay.production.draftCompletionPending';
  static const productionDraftPendingHint =
      'screenplay.production.draftPendingHint';
  static const productionDraftExpired = 'screenplay.production.draftExpired';
  static const productionDraftExpiredHint =
      'screenplay.production.draftExpiredHint';
  static const productionDraftDeadline = 'screenplay.production.draftDeadline';
  static const productionDraftSource = 'screenplay.production.draftSource';
  static const productionViewDraft = 'screenplay.production.viewDraft';
  static const productionDraftUnavailable =
      'screenplay.production.draftUnavailable';
  static const productionSampleOption = 'screenplay.production.sampleOption';
  static const productionSampleSpec = 'screenplay.production.sampleSpec';
  static const productionSampleTag = 'screenplay.production.sampleTag';
  static const productionFinalTag = 'screenplay.production.finalTag';
  static const productionDraftCompleted =
      'screenplay.production.draftCompleted';
  static const productionCompleteSource =
      'screenplay.production.completeSource';
  static const productionCompleteInputs =
      'screenplay.production.completeInputs';
  static const productionCompleteInputsValue =
      'screenplay.production.completeInputsValue';
  static const productionCompleteChanged =
      'screenplay.production.completeChanged';
  static const productionExportSamplesTitle =
      'screenplay.production.exportSamplesTitle';
  static const productionExportAnyway = 'screenplay.production.exportAnyway';
  static const productionAdopt = 'screenplay.production.adopt';
  static const productionConfirm = 'screenplay.production.confirm';
  static const productionUpload = 'screenplay.production.upload';
  static const productionPrompt = 'screenplay.production.prompt';
  static const productionInvalid = 'screenplay.production.invalid';
  static const productionFailed = 'screenplay.production.failed';
  static const productionExport = 'screenplay.production.export';
  static const productionExportResult = 'screenplay.production.exportResult';
  static const productionVideoFile = 'screenplay.production.videoFile';
  static const productionEmpty = 'screenplay.production.empty';
  static const productionResultPending = 'screenplay.production.resultPending';
  static const productionFirstFrame = 'screenplay.production.firstFrame';
  static const productionLastFrame = 'screenplay.production.lastFrame';
  static const productionFirstFrameReference =
      'screenplay.production.firstFrameReference';
  static const productionLastFrameReference =
      'screenplay.production.lastFrameReference';
  static const productionFrameReferenceHint =
      'screenplay.production.frameReferenceHint';
  static const productionReferenceImage =
      'screenplay.production.referenceImage';
  static const productionReferenceVideo =
      'screenplay.production.referenceVideo';
  static const productionReferenceAudio =
      'screenplay.production.referenceAudio';
  static const productionSource = 'screenplay.production.source';
  static const productionConnect = 'screenplay.production.connect';

  static const storyboardBoard = 'screenplay.storyboard.board';
  static const storyboardSettings = 'screenplay.storyboard.settings';
  static const storyboardNoEpisode = 'screenplay.storyboard.no_episode';
  static const storyboardNoScenes = 'screenplay.storyboard.no_scenes';
  static const storyboardTitle = 'screenplay.storyboard.title';
  static const storyboardPrompt = 'screenplay.storyboard.prompt';
  static const storyboardStatus = 'screenplay.storyboard.status';
  static const productionSelected = 'screenplay.production.selected';
  static const productionUnselected = 'screenplay.production.unselected';
  static const productionResultSaveFailed =
      'screenplay.production.resultSaveFailed';
  static const productionFailureKeepsResult =
      'screenplay.production.failureKeepsResult';
  static const productionFailureNoResult =
      'screenplay.production.failureNoResult';
  static const productionRetrySave = 'screenplay.production.retrySave';
  static const productionRetryDownload = 'screenplay.production.retryDownload';
  static const productionRetryFetch = 'screenplay.production.retryFetch';
  static const productionRetrySaveHint = 'screenplay.production.retrySaveHint';
  static const productionViewReason = 'screenplay.production.viewReason';
  static const productionDismissFailure =
      'screenplay.production.dismissFailure';
  static const storyboardModel = 'screenplay.storyboard.model';
  static const storyboardUnconfigured = 'screenplay.storyboard.unconfigured';
  static const storyboardMode = 'screenplay.storyboard.mode';
  static const storyboardFirstLastFrame =
      'screenplay.storyboard.first_last_frame';
  static const storyboardReference = 'screenplay.storyboard.reference';
  static const storyboardDuration = 'screenplay.storyboard.duration';
  static const storyboardDurationMs = 'screenplay.storyboard.duration_ms';
  static const storyboardRatio = 'screenplay.storyboard.ratio';
  static const storyboardResolution = 'screenplay.storyboard.resolution';
  static const storyboardWidth = 'screenplay.storyboard.width';
  static const storyboardHeight = 'screenplay.storyboard.height';
  static const storyboardFps = 'screenplay.storyboard.fps';
  static const storyboardSource = 'screenplay.storyboard.source';
  static const storyboardScene = 'screenplay.storyboard.scene';
  static const storyboardNumber = 'screenplay.storyboard.number';
  static const storyboardSpec = 'screenplay.storyboard.spec';
  static const storyboardAssets = 'screenplay.storyboard.assets';
  static const storyboardError = 'screenplay.storyboard.error';
  static const storyboardInvalidConfig = 'screenplay.storyboard.invalid_config';
  static const storyboardInvalidPrompt = 'screenplay.storyboard.invalid_prompt';
  static const storyboardSourceMissing = 'screenplay.storyboard.source_missing';
  static const storyboardCrossEpisodeMove =
      'screenplay.storyboard.cross_episode_move';
  static const storyboardDeleteConfirm = 'screenplay.storyboard.delete_confirm';
  static const storyboardCopyTo = 'screenplay.storyboard.copy_to';
  static const storyboardMoveTo = 'screenplay.storyboard.move_to';
  static const storyboardUnsaved = 'screenplay.storyboard.unsaved';
  static const storyboardUnsavedDetail = 'screenplay.storyboard.unsaved_detail';
  static const storyboardStay = 'screenplay.storyboard.stay';
  static const storyboardDiscard = 'screenplay.storyboard.discard';
  static const storyboardUp = 'screenplay.storyboard.up';
  static const storyboardDown = 'screenplay.storyboard.down';
  static const storyboardChooseScene = 'screenplay.storyboard.choose_scene';

  static const settingsProviderAudioModelsLabel =
      'settings.provider_audio_models_label';
  static const settingsProviderAssetSection = 'settings.provider_asset_section';
  static const settingsProviderAssetAccessKeyLabel =
      'settings.provider_asset_access_key_label';
  static const settingsProviderAssetSecretKeyLabel =
      'settings.provider_asset_secret_key_label';
  static const settingsProviderAssetProjectLabel =
      'settings.provider_asset_project_label';
  static const settingsProviderAssetProjectHint =
      'settings.provider_asset_project_hint';
  static const productionAudioReferenceInvalid =
      'screenplay.production.audioReferenceInvalid';
  static const productionAudioReferenceMixed =
      'screenplay.production.audioReferenceMixed';
  static const productionAudioReferenceCount =
      'screenplay.production.audioReferenceCount';
  static const productionAudioReferenceSize =
      'screenplay.production.audioReferenceSize';
  static const productionAudioReferenceDuration =
      'screenplay.production.audioReferenceDuration';
  static const productionAudioReferenceFormat =
      'screenplay.production.audioReferenceFormat';
  static const productionAudioOutputUnavailable =
      'screenplay.production.audioOutputUnavailable';
  static const productionAudioPromptLength =
      'screenplay.production.audioPromptLength';
  static const productionAudioPrompt = 'screenplay.production.audioPrompt';
  static const productionAudioImagePrompt =
      'screenplay.production.audioImagePrompt';
  static const productionAudioReferenceLabel =
      'screenplay.production.audioReferenceLabel';
  static const productionAudioReferenceHint =
      'screenplay.production.audioReferenceHint';
  static const productionAudioInterrupted =
      'screenplay.production.audioInterrupted';
  static const settingsProviderTypeVolcengine =
      'settings.provider_type_volcengine';
  static const settingsProviderModelIdHint = 'settings.provider_model_id_hint';
  static const settingsProviderVideoModelsLabel =
      'settings.provider_video_models_label';
  // ── account ────────────────────────────────────────
  static const accountUsageCached = 'account.usage_cached';
  // ── agent ────────────────────────────────────────
  static const agentBasics = 'agent.basics';
  static const agentDeleteConfirm = 'agent.delete_confirm';
  static const agentDescription = 'agent.description';
  static const agentDescriptionsArtist = 'agent.descriptions.artist';
  static const agentDescriptionsChronicler = 'agent.descriptions.chronicler';
  static const agentDescriptionsMonologueNarrator =
      'agent.descriptions.monologue_narrator';
  static const agentDescriptionsPlanner = 'agent.descriptions.planner';
  static const agentDescriptionsRoleplayMaster =
      'agent.descriptions.roleplay_master';
  static const agentDescriptionsTheaterActor =
      'agent.descriptions.theater_actor';
  static const agentDescriptionsWriter = 'agent.descriptions.writer';
  static const agentDuplicateName = 'agent.duplicate_name';
  static const agentEmpty = 'agent.empty';
  static const agentEnabled = 'agent.enabled';
  static const agentGlobal = 'agent.global';
  static const agentModel = 'agent.model';
  static const agentModelNotSelected = 'agent.model_not_selected';
  static const agentName = 'agent.name';
  static const agentNameRequired = 'agent.name_required';
  static const agentNoSubagentsAvailable = 'agent.no_subagents_available';
  static const agentNovel = 'agent.novel';
  static const agentRole = 'agent.role';
  static const agentRoleArtist = 'agent.role_artist';
  static const agentRoleCustom = 'agent.role_custom';
  static const agentRolePlanner = 'agent.role_planner';
  static const agentRoleReviewer = 'agent.role_reviewer';
  static const agentRoleWriter = 'agent.role_writer';
  static const agentRestoreBuiltin = 'agent.restore_builtin';
  static const agentRestoreBuiltinDescription =
      'agent.restore_builtin_description';
  static const agentRestoreBuiltinFailed = 'agent.restore_builtin_failed';
  static const agentRestoreBuiltinNoChanges =
      'agent.restore_builtin_no_changes';
  static const agentRestoreBuiltinOverwrite = 'agent.restore_builtin_overwrite';
  static const agentRestoreBuiltinOverwriteDescription =
      'agent.restore_builtin_overwrite_description';
  static const agentRestoreBuiltinSuccess = 'agent.restore_builtin_success';
  static const agentSubagents = 'agent.subagents';
  static const agentSubtitle = 'agent.subtitle';
  static const agentSystemPrompt = 'agent.system_prompt';
  static const agentSystemPromptHint = 'agent.system_prompt_hint';
  static const agentSystemPromptPlaceholder = 'agent.system_prompt_placeholder';
  static const agentSystemPromptRequired = 'agent.system_prompt_required';
  static const agentTitle = 'agent.title';
  static const agentTools = 'agent.tools';
  static const agentToolsHint = 'agent.tools_hint';
  static const agentUseCustomPrompt = 'agent.use_custom_prompt';
  static const agentUseCustomPromptDescription =
      'agent.use_custom_prompt_description';
  // ── agent_rule ────────────────────────────────────────
  static const agentRuleContent = 'agent_rule.content';
  static const agentRuleCount = 'agent_rule.count';
  static const agentRuleContentHint = 'agent_rule.content_hint';
  static const agentRuleContentLongHint = 'agent_rule.content_long_hint';
  static const agentRuleContentRequired = 'agent_rule.content_required';
  static const agentRuleCopyConfirm = 'agent_rule.copy_confirm';
  static const agentRuleCopyExists = 'agent_rule.copy_exists';
  static const agentRuleCopyExistsHint = 'agent_rule.copy_exists_hint';
  static const agentRuleCopyFailed = 'agent_rule.copy_failed';
  static const agentRuleCopyFromNovel = 'agent_rule.copy_from_novel';
  static const agentRuleCopyNoOtherNovels = 'agent_rule.copy_no_other_novels';
  static const agentRuleCopySearchNovelHint =
      'agent_rule.copy_search_novel_hint';
  static const agentRuleCopySelectNovelHint =
      'agent_rule.copy_select_novel_hint';
  static const agentRuleCopySourceEmpty = 'agent_rule.copy_source_empty';
  static const agentRuleCopySourceNovel = 'agent_rule.copy_source_novel';
  static const agentRuleCopySuccess = 'agent_rule.copy_success';
  static const agentRuleDeleteConfirm = 'agent_rule.delete_confirm';
  static const agentRuleDisabled = 'agent_rule.disabled';
  static const agentRuleDuplicateName = 'agent_rule.duplicate_name';
  static const agentRuleEditSubtitle = 'agent_rule.edit_subtitle';
  static const agentRuleEmpty = 'agent_rule.empty';
  static const agentRuleEnabled = 'agent_rule.enabled';
  static const agentRuleListHint = 'agent_rule.list_hint';
  static const agentRuleModes = 'agent_rule.modes';
  static const agentRuleName = 'agent_rule.name';
  static const agentRuleNameRequired = 'agent_rule.name_required';
  static const agentRuleNextChatHint = 'agent_rule.next_chat_hint';
  static const agentRuleOverviewHint = 'agent_rule.overview_hint';
  static const agentRuleSaveBeforeDragHint = 'agent_rule.save_before_drag_hint';
  static const agentRuleTitle = 'agent_rule.title';
  // ── agent_shortcut ────────────────────────────────────────
  static const agentShortcutApplicableLocations =
      'agent_shortcut.applicable_locations';
  static const agentShortcutAutoSend = 'agent_shortcut.auto_send';
  static const agentShortcutBuiltin = 'agent_shortcut.builtin';
  static const agentShortcutCustom = 'agent_shortcut.custom';
  static const agentShortcutDisabled = 'agent_shortcut.disabled';
  static const agentShortcutDeleteConfirm = 'agent_shortcut.delete_confirm';
  static const agentShortcutDuplicateName = 'agent_shortcut.duplicate_name';
  static const agentShortcutEmpty = 'agent_shortcut.empty';
  static const agentShortcutEnabled = 'agent_shortcut.enabled';
  static const agentShortcutLocationChapter = 'agent_shortcut.location.chapter';
  static const agentShortcutLocationCharacter =
      'agent_shortcut.location.character';
  static const agentShortcutLocationCreature =
      'agent_shortcut.location.creature';
  static const agentShortcutLocationFaction = 'agent_shortcut.location.faction';
  static const agentShortcutLocationForeshadowing =
      'agent_shortcut.location.foreshadowing';
  static const agentShortcutLocationItem = 'agent_shortcut.location.item';
  static const agentShortcutLocationMaterial =
      'agent_shortcut.location.material';
  static const agentShortcutLocationNovelDescription =
      'agent_shortcut.location.novel_description';
  static const agentShortcutLocationOutline = 'agent_shortcut.location.outline';
  static const agentShortcutLocationOutlineBeat =
      'agent_shortcut.location.outline_beat';
  static const agentShortcutLocationSkillEntry =
      'agent_shortcut.location.skill_entry';
  static const agentShortcutLocationWorldbuilding =
      'agent_shortcut.location.worldbuilding';
  static const agentShortcutLocationsRequired =
      'agent_shortcut.locations_required';
  static const agentShortcutName = 'agent_shortcut.name';
  static const agentShortcutNameRequired = 'agent_shortcut.name_required';
  static const agentShortcutPrompt = 'agent_shortcut.prompt';
  static const agentShortcutPromptHint = 'agent_shortcut.prompt_hint';
  static const agentShortcutPromptRequired = 'agent_shortcut.prompt_required';
  static const agentShortcutRestoreDefault = 'agent_shortcut.restore_default';
  static const agentShortcutRestoreDefaultConfirm =
      'agent_shortcut.restore_default_confirm';
  static const agentShortcutSubtitle = 'agent_shortcut.subtitle';
  static const agentShortcutTitle = 'agent_shortcut.title';
  // ── agent_skill ────────────────────────────────────────
  static const agentSkillMarketNotConnected =
      'agent_skill.market_not_connected';
  static const agentSkillCount = 'agent_skill.count';
  static const agentSkillDeleteConfirm = 'agent_skill.delete_confirm';
  static const agentSkillDescription = 'agent_skill.description';
  static const agentSkillDuplicateName = 'agent_skill.duplicate_name';
  static const agentSkillEmpty = 'agent_skill.empty';
  static const agentSkillDisabled = 'agent_skill.disabled';
  static const agentSkillEnabled = 'agent_skill.enabled';
  static const agentSkillGlobal = 'agent_skill.global';
  static const agentSkillName = 'agent_skill.name';
  static const agentSkillNameRequired = 'agent_skill.name_required';
  static const agentSkillSlashSection = 'agent_skill.slash_section';
  static const agentSkillNovel = 'agent_skill.novel';
  static const agentSkillOverviewHint = 'agent_skill.overview_hint';
  static const agentSkillPrompt = 'agent_skill.prompt';
  static const agentSkillPromptHint = 'agent_skill.prompt_hint';
  static const agentSkillPromptRequired = 'agent_skill.prompt_required';
  static const agentSkillReferences = 'agent_skill.references';
  static const agentSkillReferencesAdd = 'agent_skill.references_add';
  static const agentSkillReferencesEmpty = 'agent_skill.references_empty';
  static const agentSkillReferencesFileName =
      'agent_skill.references_file_name';
  static const agentSkillReferencesContentHint =
      'agent_skill.references_content_hint';
  static const agentSkillReferencesNew = 'agent_skill.references_new';
  static const agentSkillReferencesContent = 'agent_skill.references_content';
  static const agentSkillReferencesFileNameInvalid =
      'agent_skill.references_file_name_invalid';
  static const agentSkillReferencesContentRequired =
      'agent_skill.references_content_required';
  static const agentSkillMainDocument = 'agent_skill.main_document';
  static const agentSkillFiles = 'agent_skill.files';
  static const agentSkillSubtitle = 'agent_skill.subtitle';
  static const agentSkillTitle = 'agent_skill.title';
  static const agentSkillWhenToUse = 'agent_skill.when_to_use';
  static const agentSkillWhenToUseHelp = 'agent_skill.when_to_use_help';
  static const agentSkillWhenToUseRequired = 'agent_skill.when_to_use_required';
  // ── AgentSkill Setup(技能库与小说级安装)──────────────────────────────
  static const agentSkillSetupTitle = 'agent_skill.setup_title';
  static const agentSkillSetupHomeTitle = 'agent_skill.setup_home_title';
  static const agentSkillTabInstalled = 'agent_skill.tab_installed';
  static const agentSkillTabLibrary = 'agent_skill.tab_library';
  static const agentSkillTabOfficial = 'agent_skill.tab_official';
  static const agentSkillTabMarket = 'agent_skill.tab_market';
  static const agentSkillCreateAndInstall = 'agent_skill.create_and_install';
  static const agentSkillInstall = 'agent_skill.install';
  static const agentSkillDownloaded = 'agent_skill.downloaded';
  static const agentSkillInstalledEmptyTitle =
      'agent_skill.installed_empty_title';
  static const agentSkillInstalledEmptyText =
      'agent_skill.installed_empty_text';
  static const agentSkillLibraryEmptyTitle = 'agent_skill.library_empty_title';
  static const agentSkillLibraryEmptyText = 'agent_skill.library_empty_text';
  static const agentSkillUpgradeAvailable = 'agent_skill.upgrade_available';
  static const agentSkillBlocked = 'agent_skill.blocked';
  static const agentSkillSaveToLibrary = 'agent_skill.save_to_library';
  static const agentSkillRenameCallName = 'agent_skill.rename_call_name';
  static const agentSkillRemove = 'agent_skill.remove';
  static const agentSkillCallName = 'agent_skill.call_name';
  static const agentSkillCallNameHint = 'agent_skill.call_name_hint';
  static const agentSkillCallNameTaken = 'agent_skill.call_name_taken';
  static const agentSkillConflictTitle = 'agent_skill.conflict_title';
  static const agentSkillConflictSub = 'agent_skill.conflict_sub';
  static const agentSkillConflictNote = 'agent_skill.conflict_note';
  static const agentSkillOverwrite = 'agent_skill.overwrite';
  static const agentSkillRenameInstall = 'agent_skill.rename_install';
  static const agentSkillNewCallName = 'agent_skill.new_call_name';
  static const agentSkillSaveLibTitle = 'agent_skill.save_lib_title';
  static const agentSkillSaveCopy = 'agent_skill.save_copy';
  static const agentSkillLibraryConflictTitle =
      'agent_skill.library_conflict_title';
  static const agentSkillLibraryConflictSub =
      'agent_skill.library_conflict_sub';
  static const agentSkillLibraryConflictImpact =
      'agent_skill.library_conflict_impact';
  static const agentSkillLinkExistingLibrary =
      'agent_skill.link_existing_library';
  static const agentSkillOverwriteLibrary = 'agent_skill.overwrite_library';
  static const agentSkillCreateRenamedLibrary =
      'agent_skill.create_renamed_library';
  static const agentSkillLibraryName = 'agent_skill.library_name';
  static const agentSkillConvertToLocal = 'agent_skill.convert_to_local';
  static const agentSkillGoToLibrary = 'agent_skill.go_to_library';
  static const agentSkillEditInLibrary = 'agent_skill.edit_in_library';
  static const agentSkillEditInLibraryConfirmTitle =
      'agent_skill.edit_in_library_confirm_title';
  static const agentSkillEditInLibraryConfirmMessage =
      'agent_skill.edit_in_library_confirm_message';
  static const agentSkillToastConvertedLocal =
      'agent_skill.toast_converted_local';
  static const agentSkillDeleteLibraryConfirm =
      'agent_skill.delete_library_confirm';
  static const agentSkillUpgradeTitle = 'agent_skill.upgrade_title';
  static const agentSkillUpgradeNote = 'agent_skill.upgrade_note';
  static const agentSkillConfirmUpgrade = 'agent_skill.confirm_upgrade';
  static const agentSkillRevokedTitle = 'agent_skill.revoked_title';
  static const agentSkillRevokedNote = 'agent_skill.revoked_note';
  static const agentSkillGotIt = 'agent_skill.got_it';
  static const agentSkillSearchPlaceholder = 'agent_skill.search_placeholder';
  static const agentSkillCategoryAll = 'agent_skill.category_all';
  static const agentSkillSourceNovelLocal = 'agent_skill.source_novel_local';
  static const agentSkillSourceLibrary = 'agent_skill.source_library';
  static const agentSkillSourceOfficial = 'agent_skill.source_official';
  static const agentSkillSourceMarketplace = 'agent_skill.source_marketplace';
  static const agentSkillUpdatedAt = 'agent_skill.updated_at';
  static const agentSkillMineUnavailableTitle =
      'agent_skill.mine_unavailable_title';
  static const agentSkillMineUnavailableText =
      'agent_skill.mine_unavailable_text';
  static const agentSkillToastInstalled = 'agent_skill.toast_installed';
  static const agentSkillToastOverwritten = 'agent_skill.toast_overwritten';
  static const agentSkillToastRenamed = 'agent_skill.toast_renamed';
  static const agentSkillToastRemoved = 'agent_skill.toast_removed';
  static const agentSkillToastSavedLib = 'agent_skill.toast_saved_lib';
  static const agentSkillToastUpgraded = 'agent_skill.toast_upgraded';
  static const agentSkillToastCreated = 'agent_skill.toast_created';
  static const agentSkillPromptHintSetup = 'agent_skill.prompt_hint_setup';
  static const agentSkillWhenToUseHint = 'agent_skill.when_to_use_hint';
  static const agentSkillDescriptionHint = 'agent_skill.description_hint';
  static const agentSkillCallNamePlaceholder =
      'agent_skill.call_name_placeholder';
  static const agentSkillNamePlaceholder = 'agent_skill.name_placeholder';
  static const agentSkillCategory = 'agent_skill.category';
  static const agentSkillCategoryPlaceholder =
      'agent_skill.category_placeholder';
  static const agentSkillCategoryRequired = 'agent_skill.category_required';
  static const agentSkillLoadFailed = 'agent_skill.load_failed';
  static const agentSkillRetry = 'agent_skill.retry';
  static const agentSkillInstallFromOfficial =
      'agent_skill.install_from_official';
  static const agentSkillInstallInvalidSource =
      'agent_skill.install_invalid_source';
  static const agentSkillInstallSourceNotFound =
      'agent_skill.install_source_not_found';
  static const agentSkillInstallConfirmQuestion =
      'agent_skill.install_confirm_question';
  static const agentSkillInstallCancel = 'agent_skill.install_cancel';
  static const agentSkillInstallCancelled = 'agent_skill.install_cancelled';
  static const agentSkillInstallConflictQuestion =
      'agent_skill.install_conflict_question';
  static const agentSkillInstallRenamePrompt =
      'agent_skill.install_rename_prompt';
  static const agentSkillInstallFailed = 'agent_skill.install_failed';
  static const agentSkillUpgradePrompt = 'agent_skill.upgrade_prompt';
  static const agentSkillUpgradeFromV = 'agent_skill.upgrade_from_v';
  static const agentSkillAlreadyLatest = 'agent_skill.already_latest';
  static const agentSkillOfficialEmpty = 'agent_skill.official_empty';
  static const agentSkillMineEmpty = 'agent_skill.mine_empty';
  static const agentSkillVersionLabel = 'agent_skill.version_label';
  static const agentSkillSortOrder = 'agent_skill.sort_order';
  // ── 版本历史 ────────────────────────────────────────────────────────────
  static const agentSkillHistory = 'agent_skill.history';
  static const agentSkillHistoryEmpty = 'agent_skill.history_empty';
  static const agentSkillHistoryCurrent = 'agent_skill.history_current';
  static const agentSkillHistoryFileCount = 'agent_skill.history_file_count';
  static const agentSkillHistoryDiffTitle = 'agent_skill.history_diff_title';
  static const agentSkillHistoryNoPromptChange =
      'agent_skill.history_no_prompt_change';
  static const agentSkillHistoryFiles = 'agent_skill.history_files';
  static const agentSkillHistoryCopyPrompt = 'agent_skill.history_copy_prompt';
  static const agentSkillHistoryCopyFile = 'agent_skill.history_copy_file';
  static const agentSkillHistoryCopied = 'agent_skill.history_copied';
  static const agentSkillHistorySourceBaseline =
      'agent_skill.history_source_baseline';
  static const agentSkillHistorySourceInstall =
      'agent_skill.history_source_install';
  static const agentSkillHistorySourceUserEdit =
      'agent_skill.history_source_user_edit';
  static const agentSkillHistorySourceAiEdit =
      'agent_skill.history_source_ai_edit';
  static const agentSkillHistorySourceUpgrade =
      'agent_skill.history_source_upgrade';
  // ── 官方/市场技能转本地 ──────────────────────────────────────────────────
  static const agentSkillConvertedToLocal = 'agent_skill.converted_to_local';
  // ── Legacy Skill 迁移通知 ──────────────────────────────────────────────
  static const agentSkillMigrationNoticeTitle =
      'agent_skill.migration_notice.title';
  static const agentSkillMigrationNoticeBody =
      'agent_skill.migration_notice.body';
  static const agentSkillMigrationNoticeOpenSetup =
      'agent_skill.migration_notice.open_setup';
  static const agentSkillMigrationNoticeClose =
      'agent_skill.migration_notice.close';
  static const agentSkillImport = 'agent_skill.import';
  static const agentSkillImportLocal = 'agent_skill.import_local';
  static const agentSkillImportLocalHint = 'agent_skill.import_local_hint';
  static const agentSkillImportRemote = 'agent_skill.import_remote';
  static const agentSkillImportUrlPlaceholder =
      'agent_skill.import_url_placeholder';
  static const agentSkillImportUrlHint = 'agent_skill.import_url_hint';
  static const agentSkillImportScan = 'agent_skill.import_scan';
  static const agentSkillImportInvalidUrl = 'agent_skill.import_invalid_url';
  static const agentSkillImportUnavailable = 'agent_skill.import_unavailable';
  static const agentSkillImportRateLimited = 'agent_skill.import_rate_limited';
  static const agentSkillImportNetworkFailed =
      'agent_skill.import_network_failed';
  static const agentSkillImportTooLarge = 'agent_skill.import_too_large';
  static const agentSkillImportAction = 'agent_skill.import_action';
  static const agentSkillImportHint = 'agent_skill.import_hint';
  static const agentSkillImportSubtitle = 'agent_skill.import_subtitle';
  static const agentSkillImportSelectFolder =
      'agent_skill.import_select_folder';
  static const agentSkillImportSelectFile = 'agent_skill.import_select_file';
  static const agentSkillImportSelectSkills =
      'agent_skill.import_select_skills';
  static const agentSkillImportSelectAll = 'agent_skill.import_select_all';
  static const agentSkillImportDeselectAll = 'agent_skill.import_deselect_all';
  static const agentSkillImportSelectedCount =
      'agent_skill.import_selected_count';
  static const agentSkillImportConfirm = 'agent_skill.import_confirm';
  static const agentSkillImportExists = 'agent_skill.import_exists';
  static const agentSkillImportEmpty = 'agent_skill.import_empty';
  static const agentSkillImportSuccess = 'agent_skill.import_success';
  static const agentSkillImportPartial = 'agent_skill.import_partial';
  static const agentSkillImportFailed = 'agent_skill.import_failed';
  static const agentSkillExport = 'agent_skill.export';
  static const agentSkillExportAction = 'agent_skill.export_action';
  static const agentSkillExportSubtitle = 'agent_skill.export_subtitle';
  static const agentSkillExportFormat = 'agent_skill.export_format';
  static const agentSkillExportFolder = 'agent_skill.export_folder';
  static const agentSkillExportFolderHint = 'agent_skill.export_folder_hint';
  static const agentSkillExportZip = 'agent_skill.export_zip';
  static const agentSkillExportZipHint = 'agent_skill.export_zip_hint';
  static const agentSkillExportSelectSkills =
      'agent_skill.export_select_skills';
  static const agentSkillExportSelectAll = 'agent_skill.export_select_all';
  static const agentSkillExportDeselectAll = 'agent_skill.export_deselect_all';
  static const agentSkillExportSelectedCount =
      'agent_skill.export_selected_count';
  static const agentSkillExportConfirm = 'agent_skill.export_confirm';
  static const agentSkillExportSelectFolder =
      'agent_skill.export_select_folder';
  static const agentSkillExportSaveZip = 'agent_skill.export_save_zip';
  static const agentSkillExportSuccess = 'agent_skill.export_success';
  static const agentSkillExportPartial = 'agent_skill.export_partial';
  static const agentSkillExportFailed = 'agent_skill.export_failed';
  static const agentSkillExportEmpty = 'agent_skill.export_empty';
  // ── agent_studio ────────────────────────────────────────
  static const agentStudioChat = 'agent_studio.chat';
  static const agentStudioChatDescription = 'agent_studio.chat_description';
  static const agentStudioChronicler = 'agent_studio.chronicler';
  static const agentStudioChroniclerDescription =
      'agent_studio.chronicler_description';
  static const agentStudioCouncilExperts = 'agent_studio.council_experts';
  static const agentStudioExplorer = 'agent_studio.explorer';
  static const agentStudioExplorerDescription =
      'agent_studio.explorer_description';
  static const agentStudioExecutionExperts = 'agent_studio.execution_experts';
  static const agentStudioExpertTeam = 'agent_studio.expert_team';
  static const agentStudioExpertTeamDescription =
      'agent_studio.expert_team_description';
  static const agentStudioExpertTeamEmpty = 'agent_studio.expert_team_empty';
  static const agentStudioEditPrompt = 'agent_studio.edit_prompt';
  static const agentStudioImage = 'agent_studio.image';
  static const agentStudioImageDescription = 'agent_studio.image_description';
  static const agentStudioModelLabel = 'agent_studio.model_label';
  static const agentStudioModelSettings = 'agent_studio.model_settings';
  static const agentStudioModelSettingsDescription =
      'agent_studio.model_settings_description';
  static const agentStudioMyExperts = 'agent_studio.my_experts';
  static const agentStudioOfficialExperts = 'agent_studio.official_experts';
  static const agentStudioOfficialExpertsHint =
      'agent_studio.official_experts_hint';
  static const agentStudioReview = 'agent_studio.review';
  static const agentStudioReviewDescription = 'agent_studio.review_description';
  static const agentStudioSearchExperts = 'agent_studio.search_experts';
  static const agentStudioStylePolish = 'agent_studio.style_polish';
  static const agentStudioStylePolishDescription =
      'agent_studio.style_polish_description';
  static const agentStudioWriter = 'agent_studio.writer';
  static const agentStudioWriterDescription = 'agent_studio.writer_description';
  // ── ai ────────────────────────────────────────
  static const aiToolStoryState = 'ai.tool_story_state';
  static const aiToolSchema = 'ai.tool_schema';
  static const aiToolSchemaShared = 'ai.tool_schema_shared';
  static const aiToolSchemaNovel = 'ai.tool_schema_novel';
  static const aiAccept = 'ai.accept';
  static const aiAddModel = 'ai.add_model';
  static const aiAgentQuickPlotStructure = 'ai.agent_quick_plot_structure';
  static const aiAgentQuickPlotStructureSub =
      'ai.agent_quick_plot_structure_sub';
  static const aiAgentQuickArtistCharacter = 'ai.agent_quick_artist_character';
  static const aiAgentQuickArtistCharacterPrompt =
      'ai.agent_quick_artist_character_prompt';
  static const aiAgentQuickArtistCharacterSub =
      'ai.agent_quick_artist_character_sub';
  static const aiAgentQuickArtistCover = 'ai.agent_quick_artist_cover';
  static const aiAgentQuickArtistCoverPrompt =
      'ai.agent_quick_artist_cover_prompt';
  static const aiAgentQuickArtistCoverSub = 'ai.agent_quick_artist_cover_sub';
  static const aiAgentQuickChroniclerContinuity =
      'ai.agent_quick_chronicler_continuity';
  static const aiAgentQuickChroniclerContinuityPrompt =
      'ai.agent_quick_chronicler_continuity_prompt';
  static const aiAgentQuickChroniclerContinuitySub =
      'ai.agent_quick_chronicler_continuity_sub';
  static const aiAgentQuickChroniclerFacts = 'ai.agent_quick_chronicler_facts';
  static const aiAgentQuickChroniclerFactsPrompt =
      'ai.agent_quick_chronicler_facts_prompt';
  static const aiAgentQuickChroniclerFactsSub =
      'ai.agent_quick_chronicler_facts_sub';
  static const aiAgentQuickCustomContext = 'ai.agent_quick_custom_context';
  static const aiAgentQuickCustomContextPrompt =
      'ai.agent_quick_custom_context_prompt';
  static const aiAgentQuickCustomContextSub =
      'ai.agent_quick_custom_context_sub';
  static const aiAgentQuickCustomStart = 'ai.agent_quick_custom_start';
  static const aiAgentQuickCustomStartPrompt =
      'ai.agent_quick_custom_start_prompt';
  static const aiAgentQuickCustomStartSub = 'ai.agent_quick_custom_start_sub';
  static const aiAgentQuickOrchestratorPlanToday =
      'ai.agent_quick_orchestrator_plan_today';
  static const aiAgentQuickOrchestratorPlanTodayPrompt =
      'ai.agent_quick_orchestrator_plan_today_prompt';
  static const aiAgentQuickOrchestratorPlanTodaySub =
      'ai.agent_quick_orchestrator_plan_today_sub';
  static const aiAgentQuickPlannerContinuity =
      'ai.agent_quick_planner_continuity';
  static const aiAgentQuickPlannerContinuityPrompt =
      'ai.agent_quick_planner_continuity_prompt';
  static const aiAgentQuickPlannerContinuitySub =
      'ai.agent_quick_planner_continuity_sub';
  static const aiAgentQuickPlannerOutline = 'ai.agent_quick_planner_outline';
  static const aiAgentQuickPlannerOutlinePrompt =
      'ai.agent_quick_planner_outline_prompt';
  static const aiAgentQuickPlannerOutlineSub =
      'ai.agent_quick_planner_outline_sub';
  static const aiAgentQuickWriterContinue = 'ai.agent_quick_writer_continue';
  static const aiAgentQuickWriterContinuePrompt =
      'ai.agent_quick_writer_continue_prompt';
  static const aiAgentQuickWriterContinueSub =
      'ai.agent_quick_writer_continue_sub';
  static const aiAgentQuickWriterDraft = 'ai.agent_quick_writer_draft';
  static const aiAgentQuickWriterDraftPrompt =
      'ai.agent_quick_writer_draft_prompt';
  static const aiAgentQuickWriterDraftSub = 'ai.agent_quick_writer_draft_sub';
  static const aiAccessDenied = 'ai.access_denied';
  static const aiAgentRunDetailTitle = 'ai.agent_run_detail_title';
  static const aiApiKeyInvalid = 'ai.api_key_invalid';
  static const aiApiKeyMissing = 'ai.api_key_missing';
  static const aiApplied = 'ai.applied';
  static const aiApplyFailed = 'ai.apply_failed';
  static const aiApplyToChapter = 'ai.apply_to_chapter';
  static const aiApplyToEntry = 'ai.apply_to_entry';
  static const aiAskUserCancelled = 'ai.ask_user.cancelled';
  static const aiAskUserErrorSelectionRequired =
      'ai.ask_user.error_selection_required';
  static const aiAskUserHint = 'ai.ask_user.hint';
  static const aiAskUserRecommended = 'ai.ask_user.recommended';
  static const aiAskUserStatusAnswered = 'ai.ask_user.status_answered';
  static const aiAskUserStatusCancelled = 'ai.ask_user.status_cancelled';
  static const aiAskUserStatusError = 'ai.ask_user.status_error';
  static const aiAskUserStatusPending = 'ai.ask_user.status_pending';
  static const aiAskUserNotificationTitle = 'ai.ask_user.notification_title';
  static const aiAskUserNotificationBody = 'ai.ask_user.notification_body';
  static const aiAskUserReminderTitle = 'ai.ask_user.reminder_title';
  static const aiAskUserReminderBody = 'ai.ask_user.reminder_body';
  static const aiAskUserStatusTimedOut = 'ai.ask_user.status_timed_out';
  static const aiAskUserStatusInterrupted = 'ai.ask_user.status_interrupted';
  static const aiAskUserAutomaticAnswer = 'ai.ask_user.automatic_answer';
  static const aiAskUserUnanswered = 'ai.ask_user.unanswered';
  static const aiAskUserInterrupted = 'ai.ask_user.interrupted';
  static const aiAskUserTitle = 'ai.ask_user.title';
  static const aiAskUserYourAnswer = 'ai.ask_user.your_answer';
  static const aiAssistantQuickOutlineSubtitle =
      'ai.assistant_quick_outline_subtitle';
  static const aiAssistantQuickOutlineTitle =
      'ai.assistant_quick_outline_title';
  static const aiAssistantQuickPolishSubtitle =
      'ai.assistant_quick_polish_subtitle';
  static const aiAssistantQuickPolishTitle = 'ai.assistant_quick_polish_title';
  static const aiAssistantQuickstartTitle = 'ai.assistant_quickstart_title';
  static const aiAssistantWelcomeTitle = 'ai.assistant_welcome_title';
  static const aiAddSelectionToChat = 'ai.add_selection_to_chat';
  static const aiImageAttachmentLabel = 'ai.image_attachment_label';
  static const aiAttachmentFailed = 'ai.attachment_failed';
  static const aiAttachmentModelUnsupported = 'ai.attachment_model_unsupported';
  static const aiAttachmentUnavailable = 'ai.attachment_unavailable';
  static const aiAttachFile = 'ai.attach_file';
  static const aiContextFile = 'ai.context_file';
  static const aiContextSelection = 'ai.context_selection';
  static const aiContextFileEmpty = 'ai.context_file_empty';
  static const aiContextFileReadFailed = 'ai.context_file_read_failed';
  static const aiContextFileTooLarge = 'ai.context_file_too_large';
  static const aiContextFileUnsupported = 'ai.context_file_unsupported';
  static const aiAvatarGenRetry = 'ai.avatar_gen_retry';
  static const aiBadRequest = 'ai.bad_request';
  static const aiCancelFirst = 'ai.cancel_first';
  static const aiCompactingContext = 'ai.compacting_context';
  static const aiContextCompacted = 'ai.context_compacted';
  static const aiContextWindowExhausted = 'ai.context_window_exhausted';
  static const aiChapterContextUnavailable = 'ai.chapter_context_unavailable';
  static const aiChatCollapse = 'ai.chat.collapse';
  static const aiChatFloatCollapse = 'ai.chat_float_collapse';
  static const aiChatFloatOpen = 'ai.chat_float_open';
  static const aiClickToConfigure = 'ai.click_to_configure';
  static const aiConfigureImageModel = 'ai.configure_image_model';
  static const aiConfigureProvider = 'ai.configure_provider';
  static const aiChatExpand = 'ai.chat.expand';
  static const aiChatNewConversation = 'ai.chat_new_conversation';
  static const aiChatContinue = 'ai.chat_continue';
  static const aiChatContinueOffer = 'ai.chat_continue_offer';
  static const aiChatContinueHint = 'ai.chat_continue_hint';
  static const aiChatContinuedFrom = 'ai.chat_continued_from';
  static const aiChatSourceUnavailable = 'ai.chat_source_unavailable';
  static const aiChatHistory = 'ai.chat_history';
  static const aiFeedbackTitle = 'ai.feedback_title';
  static const aiFeedbackDescription = 'ai.feedback_description';
  static const aiFeedbackPlaceholder = 'ai.feedback_placeholder';
  static const aiFeedbackSubmitIssue = 'ai.feedback_submit_issue';
  static const aiFeedbackIssueTitle = 'ai.feedback_issue_title';
  static const aiFeedbackIssueBody = 'ai.feedback_issue_body';
  static const aiFeedbackOpenIssueFailed = 'ai.feedback_open_issue_failed';
  static const aiFeedbackDiagnosticsTitle = 'ai.feedback_diagnostics_title';
  static const aiFeedbackDiagnosticsDescription =
      'ai.feedback_diagnostics_description';
  static const aiFeedbackExport = 'ai.feedback_export';
  static const aiFeedbackExporting = 'ai.feedback_exporting';
  static const aiFeedbackExportSaved = 'ai.feedback_export_saved';
  static const aiFeedbackExportFailed = 'ai.feedback_export_failed';
  static const aiFeedbackSendEmail = 'ai.feedback_send_email';
  static const aiFeedbackEmailSubject = 'ai.feedback_email_subject';
  static const aiFeedbackEmailBody = 'ai.feedback_email_body';
  static const aiFeedbackOpenEmailFailed = 'ai.feedback_open_email_failed';
  static const aiFeedbackSession = 'ai.feedback_session';
  static const aiFeedbackModel = 'ai.feedback_model';
  static const aiFeedbackMessages = 'ai.feedback_messages';
  static const aiFork = 'ai.fork';
  static const aiForkTooltip = 'ai.fork_tooltip';
  static const aiForkSuffix = 'ai.fork_suffix';
  static const aiForkFailed = 'ai.fork_failed';
  static const aiForkConfirmTitle = 'ai.fork_confirm_title';
  static const aiForkConfirmMessage = 'ai.fork_confirm_message';
  static const aiForkConfirmAction = 'ai.fork_confirm_action';
  static const aiCommandFailed = 'ai.command_failed';
  static const aiConfirmAndWrite = 'ai.confirm_and_write';
  static const aiContentGenerationFailed = 'ai.content_generation_failed';
  static const aiCopied = 'ai.copied';
  static const aiCopy = 'ai.copy';
  static const aiCurrentChapter = 'ai.current_chapter';
  static const aiDetails = 'ai.details';
  static const aiDraftEntry = 'ai.draft_entry';
  static const aiExpandDetails = 'ai.expand_details';
  static const aiExpandEntry = 'ai.expand_entry';
  static const aiFinalOutputSection = 'ai.final_output_section';
  static const aiCurrentOutputSection = 'ai.current_output_section';
  static const aiGenerateOutline = 'ai.generate_outline';
  static const aiGeneratingContent = 'ai.generating_content';
  static const aiGeneratingOutline = 'ai.generating_outline';
  static const aiHandoffTo = 'ai.handoff_to';
  static const aiImageEditUnavailable = 'ai.image_edit_unavailable';
  static const aiImageGenUnavailable = 'ai.image_gen_unavailable';
  static const aiImageGenerated = 'ai.image_generated';
  static const aiImageGenerating = 'ai.image_generating';
  static const aiImageGenerationFailed = 'ai.image_generation_failed';
  static const aiCodexImageAuthFailed = 'ai.codex_image_auth_failed';
  static const aiCodexImageNeedsChatModel = 'ai.codex_image_needs_chat_model';
  static const aiModelUnavailable = 'ai.model_unavailable';
  static const aiModelUnavailableReselect = 'ai.model_unavailable_reselect';
  static const aiImageNoResult = 'ai.image_no_result';
  static const aiImagePathEmpty = 'ai.image_path_empty';
  static const aiImagePromptEmpty = 'ai.image_prompt_empty';
  static const aiInputHint = 'ai.input_hint';
  static const aiInputHintSkill = 'ai.input_hint_skill';
  static const aiInputHintWriting = 'ai.input_hint_writing';
  static const aiInputHintIdeas = 'ai.input_hint_ideas';
  static const aiInputHintOutline = 'ai.input_hint_outline';
  static const aiInputHintRoughIdea = 'ai.input_hint_rough_idea';
  static const aiInputHintPlot = 'ai.input_hint_plot';
  static const aiInputHintCharacter = 'ai.input_hint_character';
  static const aiInputHintWorldbuilding = 'ai.input_hint_worldbuilding';
  static const aiInputHintStart = 'ai.input_hint_start';
  static const aiInputHintDevelop = 'ai.input_hint_develop';
  static const aiInputHintWorkspace = 'ai.input_hint_workspace';
  static const aiMessageRewindAfter = 'ai.message_rewind_after';
  static const aiNetworkError = 'ai.network_error';
  static const aiNewSession = 'ai.new_session';
  static const aiNotFound = 'ai.not_found';
  static const aiResourceGone = 'ai.resource_gone';
  static const aiRequestTooLarge = 'ai.request_too_large';
  static const aiStreamingRequired = 'ai.streaming_required';
  static const aiProviderConnectionFailed = 'ai.provider_connection_failed';
  static const aiModelNotFound = 'ai.model_not_found';
  static const aiModelMissingOrDenied = 'ai.model_missing_or_denied';
  static const aiModelForbiddenForUser = 'ai.model_forbidden_for_user';
  static const aiModelRetired = 'ai.model_retired';
  static const aiModelPromotionEnded = 'ai.model_promotion_ended';
  static const aiModelUnsupported = 'ai.model_unsupported';
  static const aiModelTemporarilyUnavailable =
      'ai.model_temporarily_unavailable';
  static const aiRequestParameterUnsupported =
      'ai.request_parameter_unsupported';
  static const aiThinkingHistoryRequired = 'ai.thinking_history_required';
  static const aiContentRejected = 'ai.content_rejected';
  static const aiInputImagePrivacyRejected = 'ai.input_image_privacy_rejected';
  static const aiInputImageRejected = 'ai.input_image_rejected';
  static const aiInputVideoRejected = 'ai.input_video_rejected';
  static const aiInputAudioRejected = 'ai.input_audio_rejected';
  static const aiOutputContentRejected = 'ai.output_content_rejected';
  static const aiInputVideoPrivacyRejected = 'ai.input_video_privacy_rejected';
  static const aiInputCopyrightRejected = 'ai.input_copyright_rejected';
  static const aiOutputCopyrightRejected = 'ai.output_copyright_rejected';
  static const aiOutputImageForgeryRejected =
      'ai.output_image_forgery_rejected';
  static const aiContentReviewUnavailable = 'ai.content_review_unavailable';
  static const aiMissingRequestParameter = 'ai.missing_request_parameter';
  static const aiTaskTypeMismatch = 'ai.task_type_mismatch';
  static const aiInputImageInvalid = 'ai.input_image_invalid';
  static const aiProviderEndpointUnavailable =
      'ai.provider_endpoint_unavailable';
  static const aiProviderAccountRestricted = 'ai.provider_account_restricted';
  static const aiModelNotActivated = 'ai.model_not_activated';
  static const aiModelEndpointRequired = 'ai.model_endpoint_required';
  static const aiProviderFileQuotaExceeded = 'ai.provider_file_quota_exceeded';
  static const aiProviderResourceNotReady = 'ai.provider_resource_not_ready';
  static const aiProviderLimitExceeded = 'ai.provider_limit_exceeded';
  static const aiProviderUsageLimitReached = 'ai.provider_usage_limit_reached';
  static const aiProviderTrialQuotaExhausted =
      'ai.provider_trial_quota_exhausted';
  static const aiProviderChannelUnavailable = 'ai.provider_channel_unavailable';
  static const aiProviderQuotaExceeded = 'ai.provider_quota_exceeded';
  static const aiNotificationSessionCompletedBody =
      'ai.notification_session_completed_body';
  static const aiNotificationSessionCompletedTitle =
      'ai.notification_session_completed_title';
  static const aiNoImageModelConfigured = 'ai.no_image_model_configured';
  static const aiNoMessagesYet = 'ai.no_messages_yet';
  static const aiNotConfigured = 'ai.not_configured';
  static const aiOpeningFile = 'ai.opening_file';
  static const aiProviderPaymentRequired = 'ai.provider_payment_required';
  static const aiPhotoGenRetry = 'ai.photo_gen_retry';
  static const aiPleaseConfigure = 'ai.please_configure';
  static const aiPlugins = 'ai.plugins';
  static const aiPolishChapter = 'ai.polish_chapter';
  static const aiPreconditionFailed = 'ai.precondition_failed';
  static const aiPolishEntry = 'ai.polish_entry';
  static const aiQueuedMessageTitle = 'ai.queued_message_title';
  static const aiQueuedMessageSendNow = 'ai.queued_message_send_now';
  static const aiQueuedMessageSendingNext = 'ai.queued_message_sending_next';
  static const aiQueuedMessageSendingNextPrefix =
      'ai.queued_message_sending_next_prefix';
  static const aiQueuedMessageRemove = 'ai.queued_message_remove';
  static const aiQueuedMessageOccupied = 'ai.queued_message_occupied';
  static const aiRateLimited = 'ai.rate_limited';
  static const aiReasoningSection = 'ai.reasoning_section';
  static const aiReasoningEffort = 'ai.reasoning_effort';
  static const aiReasoningEffortNone = 'ai.reasoning_effort_none';
  static const aiReasoningEffortOn = 'ai.reasoning_effort_on';
  static const aiReasoningEffortLow = 'ai.reasoning_effort_low';
  static const aiReasoningEffortMedium = 'ai.reasoning_effort_medium';
  static const aiReasoningEffortHigh = 'ai.reasoning_effort_high';
  static const aiReasoningEffortXhigh = 'ai.reasoning_effort_xhigh';
  static const aiReasoningEffortMax = 'ai.reasoning_effort_max';
  static const aiReasoningEffortHintNone = 'ai.reasoning_effort_hint_none';
  static const aiReasoningEffortHintOn = 'ai.reasoning_effort_hint_on';
  static const aiReasoningEffortHintLow = 'ai.reasoning_effort_hint_low';
  static const aiReasoningEffortHintMedium = 'ai.reasoning_effort_hint_medium';
  static const aiReasoningEffortHintHigh = 'ai.reasoning_effort_hint_high';
  static const aiReasoningEffortHintXhigh = 'ai.reasoning_effort_hint_xhigh';
  static const aiReasoningEffortHintMax = 'ai.reasoning_effort_hint_max';
  static const aiRegenerate = 'ai.regenerate';
  static const aiReject = 'ai.reject';
  static const aiRemoved = 'ai.removed';
  static const aiRequestFailed = 'ai.request_failed';
  static const aiIncompleteResponse = 'ai.incomplete_response';
  static const aiRunInterrupted = 'ai.run_interrupted';
  static const aiRequestTimeout = 'ai.request_timeout';
  static const aiServiceOverloaded = 'ai.service_overloaded';
  static const aiStreamInterrupted = 'ai.stream_interrupted';
  static const aiRetry = 'ai.retry';
  static const aiRollbackTurnTooltip = 'ai.rollback_turn_tooltip';
  static const aiRollbackMessageConfirmTitle =
      'ai.rollback_message_confirm_title';
  static const aiRollbackMessageConfirmMessage =
      'ai.rollback_message_confirm_message';
  static const aiRollbackMessageConfirmAction =
      'ai.rollback_message_confirm_action';
  static const aiReviewContent = 'ai.review_content';
  static const aiReviewOutline = 'ai.review_outline';
  static const aiRewriteAccepted = 'ai.rewrite_accepted';
  static const aiRewriteIntro = 'ai.rewrite_intro';
  static const aiRewriteMetaDetail = 'ai.rewrite_meta_detail';
  static const aiRewriteMetaTitle = 'ai.rewrite_meta_title';
  static const aiRewriteRejected = 'ai.rewrite_rejected';
  static const aiScopedChapter = 'ai.scoped_chapter';
  static const aiScopedWorkspace = 'ai.scoped_workspace';
  static const aiSending = 'ai.sending';
  static const aiServiceUnavailable = 'ai.service_unavailable';
  static const aiSessionHistoryEmpty = 'ai.session_history_empty';
  static const aiSessionHistoryNoMatches = 'ai.session_history_no_matches';
  static const aiSessionHistorySearchPlaceholder =
      'ai.session_history_search_placeholder';
  static const aiSessionHistorySubtitle = 'ai.session_history_subtitle';
  static const aiSessionHistoryTitle = 'ai.session_history_title';
  static const aiSessionListEmpty = 'ai.session_list_empty';
  static const aiSessionProcessingBackground =
      'ai.session_processing_background';
  static const aiSessionProcessingCurrent = 'ai.session_processing_current';
  static const aiSessionModeChat = 'ai.session_mode.chat';
  static const aiSessionModeCouncil = 'ai.session_mode.council';
  static const aiSessionModeCouncilDesc = 'ai.session_mode.council_desc';
  static const aiSessionModeMonologue = 'ai.session_mode.monologue';
  static const aiSessionModeMonologueDesc = 'ai.session_mode.monologue_desc';
  static const aiSessionModeRoleplay = 'ai.session_mode.roleplay';
  static const aiSessionModeRoleplayDesc = 'ai.session_mode.roleplay_desc';
  static const aiSessionModeTheater = 'ai.session_mode.theater';
  static const aiSessionModeTheaterDesc = 'ai.session_mode.theater_desc';
  static const aiSessionTitleDefault = 'ai.session_title_default';
  static const aiSettings = 'ai.settings';
  static const aiShowInDocument = 'ai.show_in_document';
  static const aiStreamingReading = 'ai.streaming_reading';
  static const aiStreamingThinking = 'ai.streaming_thinking';
  static const aiStructureEntry = 'ai.structure_entry';
  static const aiSuggestRewrite = 'ai.suggest_rewrite';
  static const aiSwitchToWriteMode = 'ai.switch_to_write_mode';
  static const aiSynopsisExcerpt = 'ai.synopsis_excerpt';
  static const aiSynopsisFileName = 'ai.synopsis_file_name';
  static const aiSynopsisMeta = 'ai.synopsis_meta';
  static const aiSynopsisPath = 'ai.synopsis_path';
  static const aiSynopsisSaved = 'ai.synopsis_saved';
  static const aiThinking = 'ai.thinking';
  static const aiRetryingResponse = 'ai.retrying_response';
  static const aiToolActionAsking = 'ai.tool_action_asking';
  static const aiToolActionCreating = 'ai.tool_action_creating';
  static const aiToolActionCreatingRelation =
      'ai.tool_action_creating_relation';
  static const aiToolActionForkingAgent = 'ai.tool_action_forking_agent';
  static const aiToolActionGlobbing = 'ai.tool_action_globbing';
  static const aiToolActionGrepping = 'ai.tool_action_grepping';
  static const aiToolActionEditing = 'ai.tool_action_editing';
  static const aiToolActionReplacing = 'ai.tool_action_replacing';
  static const aiToolActionGeneratingAvatar =
      'ai.tool_action_generating_avatar';
  static const aiToolActionGeneratingPhoto = 'ai.tool_action_generating_photo';
  static const aiToolActionInstalling = 'ai.tool_action_installing';
  static const aiToolActionLoadingSkill = 'ai.tool_action_loading_skill';
  static const aiToolActionReading = 'ai.tool_action_reading';
  static const aiToolActionRemoving = 'ai.tool_action_removing';
  static const aiToolActionSearching = 'ai.tool_action_searching';
  static const aiToolActionAddingToLibrary = 'ai.tool_action_adding_to_library';
  static const aiToolActionSpawningAgent = 'ai.tool_action_spawning_agent';
  static const aiToolActionUpdatingTasks = 'ai.tool_action_updating_tasks';
  static const aiToolActionWebFetching = 'ai.tool_action_web_fetching';
  static const aiToolActionWebSearching = 'ai.tool_action_web_searching';
  static const aiToolActionWriting = 'ai.tool_action_writing';
  static const aiToolApproveHint = 'ai.tool_approve_hint';
  static const aiToolCallsSection = 'ai.tool_calls_section';
  static const aiCodemodeName = 'ai.tool_name_codemode';
  static const aiCodemodeRunning = 'ai.codemode_running';
  static const aiCodemodeDone = 'ai.codemode_done';
  static const aiCodemodeFailed = 'ai.codemode_failed';
  static const aiCodemodeStopped = 'ai.codemode_stopped';
  static const aiCodemodePartial = 'ai.codemode_partial';
  static const aiCodemodeSource = 'ai.codemode_source';
  static const aiCodemodeOutput = 'ai.codemode_output';
  static const aiCodemodeRerun = 'ai.codemode_rerun';
  static const aiCodemodeErrorScript = 'ai.codemode_error_script';
  static const aiCodemodeErrorTimeout = 'ai.codemode_error_timeout';
  static const aiCodemodeErrorLimit = 'ai.codemode_error_limit';
  static const aiCodemodeErrorForbidden = 'ai.codemode_error_forbidden';
  static const aiCodemodeErrorBusy = 'ai.codemode_error_busy';
  static const aiCodemodeErrorRuntime = 'ai.codemode_error_runtime';
  static const aiToolCancelled = 'ai.tool_cancelled';
  static const aiToolCallIncomplete = 'ai.tool_call_incomplete';
  static const aiToolCollectionLocations = 'ai.tool_collection_locations';
  static const aiToolCollectionListFmt = 'ai.tool_collection_list_fmt';
  static const aiToolError = 'ai.tool_error';
  static const aiToolExecutionResult = 'ai.tool_execution_result';
  static const aiToolAgentMessage = 'ai.tool_agent_message';
  static const aiToolGrepModeCount = 'ai.tool_grep_mode_count';
  static const aiToolGrepModeFiles = 'ai.tool_grep_mode_files';
  static const aiToolBeatIndexFmt = 'ai.tool_beat_index_fmt';
  static const aiToolBeatsCountFmt = 'ai.tool_beats_count_fmt';
  static const aiToolChaptersCountFmt = 'ai.tool_chapters_count_fmt';
  static const aiToolChapterTypeChapter = 'ai.tool_chapter_type_chapter';
  static const aiToolDepthFmt = 'ai.tool_depth_fmt';
  static const aiToolLineRange = 'ai.tool_line_range';
  static const aiToolLineRangeFmt = 'ai.tool_line_range_fmt';
  static const aiToolLayerDepthFmt = 'ai.tool_layer_depth_fmt';
  static const aiToolMatches = 'ai.tool_matches';
  static const aiToolMatchesCountFmt = 'ai.tool_matches_count_fmt';
  static const aiToolQueryFilterFmt = 'ai.tool_query_filter_fmt';
  static const aiToolQuerySourceType = 'ai.tool_query_source_type';
  static const aiToolQueryTargetType = 'ai.tool_query_target_type';
  static const aiToolQueryRelationType = 'ai.tool_query_relation_type';
  static const aiToolQueryChapterId = 'ai.tool_query_chapter_id';
  static const aiToolMoreResultsFmt = 'ai.tool_more_results_fmt';
  static const aiToolOutlineBeats = 'ai.tool_outline_beats';
  static const aiToolNameAskUser = 'ai.tool_name_ask_user';
  static const aiToolNameCreate = 'ai.tool_name_create';
  static const aiToolNameCreateChapter = 'ai.tool_name_create_chapter';
  static const aiToolNameCreateCharacter = 'ai.tool_name_create_character';
  static const aiToolNameCreateForeshadowing =
      'ai.tool_name_create_foreshadowing';
  static const aiToolNameCreateLocation = 'ai.tool_name_create_location';
  static const aiToolNameCreateOutline = 'ai.tool_name_create_outline';
  static const aiToolNameCreateBeat = 'ai.tool_name_create_beat';
  static const aiToolNameCreateRelation = 'ai.tool_name_create_relation';
  static const aiToolNameCreateVolume = 'ai.tool_name_create_volume';
  static const aiToolNameEditRelation = 'ai.tool_name_edit_relation';
  static const aiToolNameEdit = 'ai.tool_name_edit';
  static const aiToolNameReplace = 'ai.tool_name_replace';
  static const aiToolNameEditBeat = 'ai.tool_name_edit_beat';
  static const aiToolNameEditOutline = 'ai.tool_name_edit_outline';
  static const aiToolNameGenerateAvatar = 'ai.tool_name_generate_avatar';
  static const aiToolNameGeneratePhoto = 'ai.tool_name_generate_photo';
  static const aiToolNameGlob = 'ai.tool_name_glob';
  static const aiToolNameGrep = 'ai.tool_name_grep';
  static const aiToolNameRun = 'ai.tool_name_run';
  static const aiToolNameRead = 'ai.tool_name_read';
  static const aiToolNameRemove = 'ai.tool_name_remove';
  static const aiToolNameSearch = 'ai.tool_name_search';
  static const aiToolNameGraphSearch = 'ai.tool_name_graph_search';
  static const aiToolNameSkill = 'ai.tool_name_skill';
  static const aiToolNameSpawnAgent = 'ai.tool_name_spawn_agent';
  static const aiBackgroundAgents = 'ai.background_agents';
  static const aiBackgroundStopping = 'ai.background_stopping';
  static const aiBackgroundStopAll = 'ai.background_stop_all';
  static const aiBackgroundStopAllHint = 'ai.background_stop_all_hint';
  static const aiBackgroundNotRunning = 'ai.background_not_running';
  static const aiBackgroundStopFailed = 'ai.background_stop_failed';
  static const aiBackgroundAllSettled = 'ai.background_all_settled';
  static const aiBackgroundDone = 'ai.background_done';
  static const aiBackgroundFailed = 'ai.background_failed';
  static const aiToolNameSendAgentMessage = 'ai.tool_name_send_agent_message';
  static const aiToolNameStopAgent = 'ai.tool_name_stop_agent';
  static const aiToolNameForkAgent = 'ai.tool_name_fork_agent';
  static const aiToolNameCreateTask = 'ai.tool_name_create_task';
  static const aiToolNameListTasks = 'ai.tool_name_list_tasks';
  static const aiToolNameTodoWrite = 'ai.tool_name_todo_write';
  static const aiToolNameWebFetch = 'ai.tool_name_web_fetch';
  static const aiToolNameWebSearch = 'ai.tool_name_web_search';
  static const aiToolNameWrite = 'ai.tool_name_write';
  static const aiToolNewText = 'ai.tool_new_text';
  static const aiToolNoResults = 'ai.tool_no_results';
  static const aiToolNotAllowedFmt = 'ai.tool_not_allowed_fmt';
  static const aiToolNotInitialized = 'ai.tool_not_initialized';
  static const aiToolOldText = 'ai.tool_old_text';
  static const aiToolPathCanvasEdges = 'ai.tool_path_canvas_edges';
  static const aiToolPathCanvasLayout = 'ai.tool_path_canvas_layout';
  static const aiToolPathCanvasNodes = 'ai.tool_path_canvas_nodes';
  static const aiToolPaths = 'ai.tool_paths';
  static const aiToolPattern = 'ai.tool_pattern';
  static const aiToolPending = 'ai.tool_pending';
  static const aiToolPreview = 'ai.tool_preview';
  static const aiToolProcessCountFmt = 'ai.tool_process_count_fmt';
  static const aiToolProcessTitle = 'ai.tool_process_title';
  static const aiToolQuestion = 'ai.tool_question';
  static const aiToolRejected = 'ai.tool_rejected';
  static const aiToolReplaceAll = 'ai.tool_replace_all';
  static const aiToolResultCount = 'ai.tool_result_count';
  static const aiToolResultCountFmt = 'ai.tool_result_count_fmt';
  static const aiToolResultsTruncated = 'ai.tool_results_truncated';
  static const aiToolRunAssets = 'ai.tool_run_assets';
  static const aiToolRunAssetsList = 'ai.tool_run_assets_list';
  static const aiToolRunAssetsRead = 'ai.tool_run_assets_read';
  static const aiToolRunProviders = 'ai.tool_run_providers';
  static const aiToolRunProvidersList = 'ai.tool_run_providers_list';
  static const aiToolRunProvidersRead = 'ai.tool_run_providers_read';
  static const aiToolRunProvidersModels = 'ai.tool_run_providers_models';
  static const aiToolRunDirector = 'ai.tool_run_director';
  static const aiToolRunDirectorSchema = 'ai.tool_run_director_schema';
  static const aiToolRunDirectorPresets = 'ai.tool_run_director_presets';
  static const aiToolRunDirectorSample = 'ai.tool_run_director_sample';
  static const aiToolRunDirectorList = 'ai.tool_run_director_list';
  static const aiToolRunDirectorRead = 'ai.tool_run_director_read';
  static const aiToolRunDirectorCreate = 'ai.tool_run_director_create';
  static const aiToolRunDirectorApply = 'ai.tool_run_director_apply';
  static const aiToolRunDirectorRestore = 'ai.tool_run_director_restore';
  static const aiToolRunDirectorRemove = 'ai.tool_run_director_remove';
  static const aiToolRunDirectorPreview = 'ai.tool_run_director_preview';
  static const aiToolRunDirectorOutput = 'ai.tool_run_director_output';
  static const aiToolRunDirectorFrames = 'ai.tool_run_director_frames';
  static const aiToolRunReadFmt = 'ai.tool_run_read_fmt';
  static const aiToolRunSearchFmt = 'ai.tool_run_search_fmt';
  static const aiToolRunWebFmt = 'ai.tool_run_web_fmt';
  static const aiToolRunAgentSkillsList = 'ai.tool_run_agent_skills_list';
  static const aiToolRunAgentSkillsCreate = 'ai.tool_run_agent_skills_create';
  static const aiToolRunAgentSkillsUpdate = 'ai.tool_run_agent_skills_update';
  static const aiToolRunAgentSkillsDelete = 'ai.tool_run_agent_skills_delete';
  static const aiToolRunAgentSkillsSearch = 'ai.tool_run_agent_skills_search';
  static const aiToolRunAgentSkillsGet = 'ai.tool_run_agent_skills_get';
  static const aiToolRunAgentSkillsInstall = 'ai.tool_run_agent_skills_install';
  static const aiToolRunAgentSkillsReferenceList =
      'ai.tool_run_agent_skills_reference_list';
  static const aiToolRunAgentSkillsReferenceGet =
      'ai.tool_run_agent_skills_reference_get';
  static const aiToolRunAgentSkillsReferenceCreate =
      'ai.tool_run_agent_skills_reference_create';
  static const aiToolRunAgentSkillsReferenceUpdate =
      'ai.tool_run_agent_skills_reference_update';
  static const aiToolRunAgentSkillsReferenceMove =
      'ai.tool_run_agent_skills_reference_move';
  static const aiToolRunAgentSkillsReferenceDelete =
      'ai.tool_run_agent_skills_reference_delete';
  static const aiToolRunThemes = 'ai.tool_run_themes';
  static const aiToolRunThemesList = 'ai.tool_run_themes_list';
  static const aiToolRunThemesRead = 'ai.tool_run_themes_read';
  static const aiToolRunThemesCreate = 'ai.tool_run_themes_create';
  static const aiToolRunThemesUpdate = 'ai.tool_run_themes_update';
  static const aiToolRunThemesApply = 'ai.tool_run_themes_apply';
  static const aiToolRunThemesDelete = 'ai.tool_run_themes_delete';
  static const aiToolRunAgentRulesList = 'ai.tool_run_agent_rules_list';
  static const aiToolRunAgentRulesRead = 'ai.tool_run_agent_rules_read';
  static const aiToolRunAgentRulesCreate = 'ai.tool_run_agent_rules_create';
  static const aiToolRunAgentRulesUpdate = 'ai.tool_run_agent_rules_update';
  static const aiToolRunAgentRulesDelete = 'ai.tool_run_agent_rules_delete';
  static const aiToolRunSubagentsList = 'ai.tool_run_subagents_list';
  static const aiToolRunSubagentsCreate = 'ai.tool_run_subagents_create';
  static const aiToolRunSubagentsUpdate = 'ai.tool_run_subagents_update';
  static const aiToolRunSubagentsDelete = 'ai.tool_run_subagents_delete';
  static const aiToolRunSessionsList = 'ai.tool_run_sessions_list';
  static const aiToolRunSessionsRead = 'ai.tool_run_sessions_read';
  static const aiToolRunSessionsSearch = 'ai.tool_run_sessions_search';
  static const aiToolRunSessionsGet = 'ai.tool_run_sessions_get';
  static const aiToolRunNovelAddToLibrary = 'ai.tool_run_novel_add_to_library';
  static const aiToolRunMapDraft = 'ai.tool_run_map_draft';
  static const aiToolRunNotifyQuestion = 'ai.tool_run_notify_question';
  static const aiToolRunNotifyComplete = 'ai.tool_run_notify_complete';
  static const aiToolRunNotifyError = 'ai.tool_run_notify_error';
  static const aiToolRunImageCharacterAvatar =
      'ai.tool_run_image_character_avatar';
  static const aiToolRunImageCharacterPhoto =
      'ai.tool_run_image_character_photo';
  static const aiToolRunImageItemPhoto = 'ai.tool_run_image_item_photo';
  static const aiToolRunViewHelp = 'ai.tool_run_view_help';
  static const aiToolRunImage = 'ai.tool_run_image';
  static const aiToolRunHelpCharacterImage = 'ai.tool_run_help_character_image';
  static const aiToolRunHelpItemImage = 'ai.tool_run_help_item_image';
  static const aiToolRunNotify = 'ai.tool_run_notify';
  static const aiToolRunAgentSkills = 'ai.tool_run_agent_skills';
  static const aiToolRunAgentRules = 'ai.tool_run_agent_rules';
  static const aiToolRunSubagents = 'ai.tool_run_subagents';
  static const aiToolRunSessions = 'ai.tool_run_sessions';
  static const aiToolRunNovel = 'ai.tool_run_novel';
  static const aiToolRunHelp = 'ai.tool_run_help';
  static const aiToolRunMap = 'ai.tool_run_map';
  static const aiToolRunMapSubmit = 'ai.tool_run_map_submit';
  static const aiToolRunMapPrompt = 'ai.tool_run_map_prompt';
  static const aiToolRunMapReady = 'ai.tool_run_map_ready';
  static const aiToolRunMapStyleParchment = 'ai.tool_run_map_style_parchment';
  static const aiToolRunMapStyleInkmap = 'ai.tool_run_map_style_inkmap';
  static const aiToolRunMapStyleEngraving = 'ai.tool_run_map_style_engraving';
  static const aiToolRunMapStyleRealistic = 'ai.tool_run_map_style_realistic';
  static const aiToolRunMapStyleWoodcut = 'ai.tool_run_map_style_woodcut';
  static const aiToolRunMapStyleWatercolor = 'ai.tool_run_map_style_watercolor';
  static const aiToolRunMapStyleAtlas = 'ai.tool_run_map_style_atlas';
  static const aiToolRunMapQualityLow = 'ai.tool_run_map_quality_low';
  static const aiToolRunMapQualityMedium = 'ai.tool_run_map_quality_medium';
  static const aiToolRunMapQualityHigh = 'ai.tool_run_map_quality_high';
  static const aiToolRunNotifyProgress = 'ai.tool_run_notify_progress';
  static const aiToolRunActionListing = 'ai.tool_run_action_listing';
  static const aiToolRunSkillsCountFmt = 'ai.tool_run_skills_count_fmt';
  static const aiToolRunSubagentsCountFmt = 'ai.tool_run_subagents_count_fmt';
  static const aiToolRunRulesCountFmt = 'ai.tool_run_rules_count_fmt';
  static const aiToolRunRulesAvailableFmt = 'ai.tool_run_rules_available_fmt';
  static const aiToolRunRulesEmpty = 'ai.tool_run_rules_empty';
  static const aiToolRunDeletedRule = 'ai.tool_run_deleted_rule';
  static const aiToolRunRuleName = 'ai.tool_run_rule_name';
  static const aiToolRunRuleNewName = 'ai.tool_run_rule_new_name';
  static const aiToolRunRuleContent = 'ai.tool_run_rule_content';
  static const aiToolRunScopeFmt = 'ai.tool_run_scope_fmt';
  static const aiToolRunning = 'ai.tool_running';
  static const aiRunAwaitingSubcommand = 'ai.run_awaiting_subcommand';
  static const aiSlashExperts = 'ai.slash_experts';
  static const aiToolScope = 'ai.tool_scope';
  static const aiToolScopeRoot = 'ai.tool_scope_root';
  static const aiToolSkippedFmt = 'ai.tool_skipped_fmt';
  static const aiToolSuccess = 'ai.tool_success';
  static const aiToolTarget = 'ai.tool_target';
  static const aiToolTask = 'ai.tool_task';
  static const aiToolUsingSkill = 'ai.tool_using_skill';
  static const aiToolWorkUnavailable = 'ai.tool_work_unavailable';
  static const aiUntitledChapter = 'ai.untitled_chapter';
  static const aiUserPromptRewrite = 'ai.user_prompt_rewrite';
  static const aiUserPromptSynopsis = 'ai.user_prompt_synopsis';
  static const aiViewDiffDetail = 'ai.view_diff_detail';
  static const aiWritingAgent = 'ai.writing_agent';
  static const aiChatOnboardingTitle = 'ai.chat_onboarding_title';
  static const aiChatOnboardingMessage = 'ai.chat_onboarding_message';
  static const aiChatOnboardingDismiss = 'ai.chat_onboarding_dismiss';
  static const aiChatOnboardingFocusHint = 'ai.chat_onboarding_focus_hint';
  static const aiChatOnboardingNext = 'ai.chat_onboarding_next';
  static const aiChatOnboardingDone = 'ai.chat_onboarding_done';
  static const aiChatOnboardingAgentTitle = 'ai.chat_onboarding_agent_title';
  static const aiChatOnboardingAgentMessage =
      'ai.chat_onboarding_agent_message';
  static const aiChatOnboardingModelTitle = 'ai.chat_onboarding_model_title';
  static const aiChatOnboardingModelMessage =
      'ai.chat_onboarding_model_message';
  static const aiChatOnboardingCoverTitle = 'ai.chat_onboarding_cover_title';
  static const aiChatOnboardingCoverMessage =
      'ai.chat_onboarding_cover_message';
  static const aiFeatureOnboardingDialogGotIt =
      'ai.feature_onboarding.dialog_got_it';
  static const aiFeatureOnboardingCouncilTitle =
      'ai.feature_onboarding.council_title';
  static const aiFeatureOnboardingCouncilIntro =
      'ai.feature_onboarding.council_intro';
  static const aiFeatureOnboardingCouncilHowTo =
      'ai.feature_onboarding.council_how_to';
  static const aiFeatureOnboardingMonologueTitle =
      'ai.feature_onboarding.monologue_title';
  static const aiFeatureOnboardingMonologueIntro =
      'ai.feature_onboarding.monologue_intro';
  static const aiFeatureOnboardingMonologueHowTo =
      'ai.feature_onboarding.monologue_how_to';
  static const aiFeatureOnboardingTheaterTitle =
      'ai.feature_onboarding.theater_title';
  static const aiFeatureOnboardingTheaterIntro =
      'ai.feature_onboarding.theater_intro';
  static const aiFeatureOnboardingTheaterHowTo =
      'ai.feature_onboarding.theater_how_to';
  static const aiFeatureOnboardingRoleplayTitle =
      'ai.feature_onboarding.roleplay_title';
  static const aiFeatureOnboardingRoleplayIntro =
      'ai.feature_onboarding.roleplay_intro';
  static const aiFeatureOnboardingRoleplayHowTo =
      'ai.feature_onboarding.roleplay_how_to';
  static const aiFeatureOnboardingAgentRulesTitle =
      'ai.feature_onboarding.agent_rules_title';
  static const aiFeatureOnboardingAgentRulesIntro =
      'ai.feature_onboarding.agent_rules_intro';
  static const aiFeatureOnboardingAgentRulesHowTo =
      'ai.feature_onboarding.agent_rules_how_to';
  static const aiFeatureOnboardingCoverStudioTitle =
      'ai.feature_onboarding.cover_studio_title';
  static const aiFeatureOnboardingCoverStudioIntro =
      'ai.feature_onboarding.cover_studio_intro';
  static const aiFeatureOnboardingCoverStudioHowTo =
      'ai.feature_onboarding.cover_studio_how_to';
  static const aiFeatureOnboardingAvatarGenerationTitle =
      'ai.feature_onboarding.avatar_generation_title';
  static const aiFeatureOnboardingAvatarGenerationIntro =
      'ai.feature_onboarding.avatar_generation_intro';
  static const aiFeatureOnboardingAvatarGenerationHowTo =
      'ai.feature_onboarding.avatar_generation_how_to';
  static const aiFeatureOnboardingOutlineCraftTitle =
      'ai.feature_onboarding.outline_craft_title';
  static const aiFeatureOnboardingOutlineCraftIntro =
      'ai.feature_onboarding.outline_craft_intro';
  static const aiFeatureOnboardingOutlineCraftHowTo =
      'ai.feature_onboarding.outline_craft_how_to';
  static const aiFeatureOnboardingFeatureUsageTitle =
      'ai.feature_onboarding.feature_usage_title';
  static const aiFeatureOnboardingFeatureUsageIntro =
      'ai.feature_onboarding.feature_usage_intro';
  static const aiFeatureOnboardingFeatureUsageHowTo =
      'ai.feature_onboarding.feature_usage_how_to';
  // ── app ────────────────────────────────────────
  static const appTitle = 'app.title';
  static const appActivationUnconfirmedTitle =
      'app.activation_unconfirmed_title';
  static const appActivationUnconfirmedMessage =
      'app.activation_unconfirmed_message';
  static const appOpenLogs = 'app.open_logs';
  static const appLogsOpenFailed = 'app.logs_open_failed';
  // ── canvas ────────────────────────────────────────
  // Canvas (无限画布)
  static const canvasTitle = 'canvas.title';
  static const canvasRenameCanvas = 'canvas.rename_canvas';
  static const canvasDeleteConfirm = 'canvas.delete_confirm';
  static const canvasNameHint = 'canvas.name_hint';
  static const canvasDescriptionHint = 'canvas.description_hint';
  static const canvasNameRequired = 'canvas.name_required';
  static const canvasNameDuplicate = 'canvas.name_duplicate';
  static const canvasEmptyHint = 'canvas.empty_hint';
  static const canvasClose = 'canvas.close';
  static const canvasZoomReset = 'canvas.zoom_reset';
  static const canvasFitToView = 'canvas.fit_to_view';
  static const canvasZoomIn = 'canvas.zoom_in';
  static const canvasZoomOut = 'canvas.zoom_out';
  static const canvasZoomOptions = 'canvas.zoom_options';
  static const canvasZoomTo = 'canvas.zoom_to';
  static const canvasAddSticky = 'canvas.add_sticky';
  static const canvasStickyPlaceholder = 'canvas.sticky_placeholder';
  static const canvasAddReference = 'canvas.add_reference';
  static const canvasCleanDead = 'canvas.clean_dead';
  static const canvasAutoLayout = 'canvas.auto_layout';
  static const canvasAutoLayoutTooltip = 'canvas.auto_layout_tooltip';
  static const canvasStartAgent = 'canvas.start_agent';
  static const canvasExport = 'canvas.export';
  static const canvasExporting = 'canvas.exporting';
  static const canvasExportSaved = 'canvas.export_saved';
  static const canvasExportFailed = 'canvas.export_failed';
  static const canvasExportPartialFile = 'canvas.export_partial_file';
  static const canvasExportSaveEditsFailed = 'canvas.export_save_edits_failed';
  static const canvasArrange = 'canvas.arrange';
  static const canvasLayoutAuto = 'canvas.layout_auto';
  static const canvasLayoutTidy = 'canvas.layout_tidy';
  static const canvasLayoutTidyTooltip = 'canvas.layout_tidy_tooltip';
  static const canvasLayoutTreeLr = 'canvas.layout_tree_lr';
  static const canvasLayoutTreeTb = 'canvas.layout_tree_tb';
  static const canvasLayoutGrid = 'canvas.layout_grid';
  static const canvasLayoutNeedsNodes = 'canvas.layout_needs_nodes';
  static const canvasLayoutNeedsDirectedEdges =
      'canvas.layout_needs_directed_edges';
  static const canvasLayoutMovesAll = 'canvas.layout_moves_all';
  static const canvasLayoutMoved = 'canvas.layout_moved';
  static const canvasLayoutSaved = 'canvas.layout_saved';
  static const canvasLayoutUnchanged = 'canvas.layout_unchanged';
  static const canvasLayoutConflict = 'canvas.layout_conflict';
  static const canvasFinishInput = 'canvas.finish_input';
  static const canvasOpenScene = 'canvas.open_scene';
  static const canvasOpenSceneFailed = 'canvas.open_scene_failed';
  static const canvasResourcePickerTitle = 'canvas.resource_picker_title';
  static const canvasResourcePickerSearchHint =
      'canvas.resource_picker_search_hint';
  static const canvasResourcePickerEmpty = 'canvas.resource_picker_empty';
  static const canvasResourcePickerAlreadyOnCanvas =
      'canvas.resource_picker_already_on_canvas';
  static const canvasNodeTypeReference = 'canvas.node_type_reference';
  static const canvasNodeTypeSticky = 'canvas.node_type_sticky';
  static const canvasEdgeTypeRelationship = 'canvas.edge_type_relationship';
  static const canvasEdgeTypeCausal = 'canvas.edge_type_causal';
  static const canvasEdgeTypeTimeline = 'canvas.edge_type_timeline';
  static const canvasEdgeTypeForeshadowPayoff =
      'canvas.edge_type_foreshadow_payoff';
  static const canvasEdgeTypeAssociation = 'canvas.edge_type_association';
  static const canvasInvalidReference = 'canvas.invalid_reference';
  static const canvasInvalidReferenceTooltip =
      'canvas.invalid_reference_tooltip';
  static const canvasInvalidReferenceDetail = 'canvas.invalid_reference_detail';
  static const canvasRemoveInvalidNode = 'canvas.remove_invalid_node';
  static const canvasNodeTitle = 'canvas.node_title';
  // 边类型选择器 — 每类边的一句话说明,帮作者选对语义
  static const canvasEdgeTypePrompt = 'canvas.edge_type_prompt';
  static const canvasEdgeDescRelationship = 'canvas.edge_desc_relationship';
  static const canvasEdgeDescCausal = 'canvas.edge_desc_causal';
  static const canvasEdgeDescTimeline = 'canvas.edge_desc_timeline';
  static const canvasEdgeDescForeshadowPayoff =
      'canvas.edge_desc_foreshadow_payoff';
  static const canvasEdgeDescAssociation = 'canvas.edge_desc_association';
  static const canvasEdgeLabelHint = 'canvas.edge_label_hint';
  static const canvasEdgeDuplicate = 'canvas.edge_duplicate';
  static const canvasEdgeInvalidForeshadow = 'canvas.edge_invalid_foreshadow';
  // 节点原地详情
  static const canvasNodeConnections = 'canvas.node_connections';
  static const canvasNodeConnectionsEmpty = 'canvas.node_connections_empty';
  static const canvasStickyLabel = 'canvas.sticky_label';
  static const canvasStickyTitleHint = 'canvas.sticky_title_hint';
  static const canvasStickyColorSand = 'canvas.sticky_color_sand';
  static const canvasStickyColorSage = 'canvas.sticky_color_sage';
  static const canvasStickyColorRose = 'canvas.sticky_color_rose';
  static const canvasStickyColorStone = 'canvas.sticky_color_stone';
  static const canvasNodeColorRed = 'canvas.node_color_red';
  static const canvasNodeColorOrange = 'canvas.node_color_orange';
  static const canvasNodeColorYellow = 'canvas.node_color_yellow';
  static const canvasNodeColorGreen = 'canvas.node_color_green';
  static const canvasNodeColorTeal = 'canvas.node_color_teal';
  static const canvasNodeColorBlue = 'canvas.node_color_blue';
  static const canvasNodeColorPurple = 'canvas.node_color_purple';
  static const canvasNodeColorPink = 'canvas.node_color_pink';
  static const canvasNodeColorCustom = 'canvas.node_color_custom';
  static const canvasNodeColorNone = 'canvas.node_color_none';
  // AI 编辑画布时的状态提示与跟随开关
  static const canvasAiStatusScanning = 'canvas.ai_status_scanning';
  static const canvasAiStatusAddingNode = 'canvas.ai_status_adding_node';
  static const canvasAiStatusUpdatingNode = 'canvas.ai_status_updating_node';
  static const canvasAiStatusRemovingNode = 'canvas.ai_status_removing_node';
  static const canvasAiStatusAddingEdge = 'canvas.ai_status_adding_edge';
  static const canvasAiStatusRemovingEdge = 'canvas.ai_status_removing_edge';
  static const canvasAiStatusArranging = 'canvas.ai_status_arranging';
  static const canvasAiStatusCreatingCanvas =
      'canvas.ai_status_creating_canvas';
  static const canvasAiStatusOpeningCanvas = 'canvas.ai_status_opening_canvas';
  static const canvasAiStatusEditing = 'canvas.ai_status_editing';
  static const canvasFollowAi = 'canvas.follow_ai';
  static const canvasFollowPaused = 'canvas.follow_paused';
  static const canvasFollowResume = 'canvas.follow_resume';
  // ── chapter ────────────────────────────────────────
  static const chapterPublish = 'chapter.publish';
  static const chapterPublishChroniclerPrompt =
      'chapter.publish_chronicler_prompt';
  static const chapterRunChronicler = 'chapter.run_chronicler';
  static const chapterStatDraft = 'chapter.stat_draft';
  static const chapterStatPublished = 'chapter.stat_published';
  static const chapterUnpublish = 'chapter.unpublish';
  // ── character ────────────────────────────────────────
  static const characterGenderFemale = 'character.gender.female';
  static const characterGenderMale = 'character.gender.male';
  static const characterGenderNonBinary = 'character.gender.non_binary';
  static const characterGenderOther = 'character.gender.other';
  static const characterGenderUnknown = 'character.gender.unknown';
  static const characterRoleAntagonist = 'character.role.antagonist';
  static const characterRoleMinor = 'character.role.minor';
  static const characterRoleProtagonist = 'character.role.protagonist';
  static const characterRoleSupporting = 'character.role.supporting';
  // ── comment ────────────────────────────────────────
  static const commentAction = 'comment.action';
  static const commentContentHint = 'comment.content_hint';
  static const commentJumpUnresolved = 'comment.jump_unresolved';
  static const commentOrphaned = 'comment.orphaned';
  static const commentOrphanedHint = 'comment.orphaned_hint';
  static const commentReopen = 'comment.reopen';
  static const commentResolve = 'comment.resolve';
  static const commentResolvedTitle = 'comment.resolved_title';
  static const commentStatusLabel = 'comment.status_label';
  static const commentTitle = 'comment.title';
  static const editingTitle = 'screenplay.editing.title';
  static const editingUndo = 'screenplay.editing.undo';
  static const editingRedo = 'screenplay.editing.redo';
  static const editingSplit = 'screenplay.editing.split';
  static const editingAssets = 'screenplay.editing.assets';
  static const editingProperties = 'screenplay.editing.properties';
  static const editingDuration = 'screenplay.editing.duration';
  static const editingOpacity = 'screenplay.editing.opacity';
  static const editingFadeIn = 'screenplay.editing.fadeIn';
  static const editingFadeOut = 'screenplay.editing.fadeOut';
  static const editingLock = 'screenplay.editing.lock';
  static const editingMute = 'screenplay.editing.mute';
  static const editingReplace = 'screenplay.editing.replace';
  static const editingSelectHint = 'screenplay.editing.selectHint';
  static const editingRendering = 'screenplay.editing.rendering';
  static const editingReady = 'screenplay.editing.ready';
  static const editingCancelled = 'screenplay.editing.cancelled';
  static const editingRenderFailed = 'screenplay.editing.renderFailed';
  static const editingInvalidEdit = 'screenplay.editing.invalidEdit';
  static const editingSourceMissing = 'screenplay.editing.sourceMissing';
  static const editingConflict = 'screenplay.editing.conflict';
  static const editingReload = 'screenplay.editing.reload';
  static const editingPreviewStale = 'screenplay.editing.previewStale';
  static const editingSaved = 'screenplay.editing.saved';
  static const editingSaveBlocked = 'screenplay.editing.saveBlocked';
  static const editingDiskFull = 'screenplay.editing.diskFull';
  static const editingInvalidMedia = 'screenplay.editing.invalidMedia';
  static const editingEpisodeFileName = 'screenplay.editing.episodeFileName';
  static const editingOverwriteSubtitles =
      'screenplay.editing.overwriteSubtitles';
  static const editingOverwriteSubtitlesDetail =
      'screenplay.editing.overwriteSubtitlesDetail';
  static const editingVerifying = 'screenplay.editing.verifying';
  static const editingAssembling = 'screenplay.editing.assembling';
  static const editingValidating = 'screenplay.editing.validating';
  static const editingAudioOnly = 'screenplay.editing.audioOnly';
  static const editingTextOnly = 'screenplay.editing.textOnly';
  static const editingVisualOnly = 'screenplay.editing.visualOnly';
  static const editingOccupied = 'screenplay.editing.occupied';
  static const editingNoFreeTrack = 'screenplay.editing.noFreeTrack';
  static const editingReplaced = 'screenplay.editing.replaced';
  static const editingNewSubtitle = 'screenplay.editing.newSubtitle';
  static const editingRoleMain = 'screenplay.editing.roleMain';
  static const editingRoleOverlay = 'screenplay.editing.roleOverlay';
  static const editingRoleSubtitle = 'screenplay.editing.roleSubtitle';
  static const editingRoleDialogue = 'screenplay.editing.roleDialogue';
  static const editingRoleSfx = 'screenplay.editing.roleSfx';
  static const editingRoleMusic = 'screenplay.editing.roleMusic';
  static const editingRoleAudio = 'screenplay.editing.roleAudio';
  static const editingSnapOn = 'screenplay.editing.snapOn';
  static const editingSnapOff = 'screenplay.editing.snapOff';
  static const editingAudioTrack = 'screenplay.editing.audioTrack';
  static const editingZoomOut = 'screenplay.editing.zoomOut';
  static const editingZoomIn = 'screenplay.editing.zoomIn';
  static const editingFit = 'screenplay.editing.fit';
  static const editingMagnetHint = 'screenplay.editing.magnetHint';
  static const editingAddSubtitle = 'screenplay.editing.addSubtitle';
  static const editingRemoveTrack = 'screenplay.editing.removeTrack';
  static const editingUnlock = 'screenplay.editing.unlock';
  static const editingUnmute = 'screenplay.editing.unmute';
  static const editingShow = 'screenplay.editing.show';
  static const editingHide = 'screenplay.editing.hide';
  static const editingSplitDone = 'screenplay.editing.splitDone';
  static const editingRippleDeleted = 'screenplay.editing.rippleDeleted';
  static const editingTrackLocked = 'screenplay.editing.trackLocked';
  static const editingSourceEdge = 'screenplay.editing.sourceEdge';
  static const editingOverviewTitle = 'screenplay.editing.overviewTitle';
  static const editingPicture = 'screenplay.editing.picture';
  static const editingTracks = 'screenplay.editing.tracks';
  static const editingTrackSummary = 'screenplay.editing.trackSummary';
  static const editingKeySpace = 'screenplay.editing.keySpace';
  static const editingStyleTitle = 'screenplay.editing.styleTitle';
  static const editingStyleSubtitle = 'screenplay.editing.styleSubtitle';
  static const editingClipPosition = 'screenplay.editing.clipPosition';
  static const editingText = 'screenplay.editing.text';
  static const editingStyle = 'screenplay.editing.style';
  static const editingPosition = 'screenplay.editing.position';
  static const editingPositionTop = 'screenplay.editing.positionTop';
  static const editingPositionCenter = 'screenplay.editing.positionCenter';
  static const editingPositionBottom = 'screenplay.editing.positionBottom';
  static const editingSourceRange = 'screenplay.editing.sourceRange';
  static const editingVolume = 'screenplay.editing.volume';
  static const editingOriginalSound = 'screenplay.editing.originalSound';
  static const editingDetachAudio = 'screenplay.editing.detachAudio';
  static const editingNoSound = 'screenplay.editing.noSound';
  static const editingSize = 'screenplay.editing.size';
  static const editingFill = 'screenplay.editing.fill';
  static const editingUsedCount = 'screenplay.editing.usedCount';
  static const editingReplaceAction = 'screenplay.editing.replaceAction';
  static const editingAddAtPlayhead = 'screenplay.editing.addAtPlayhead';
  static const editingReplacing = 'screenplay.editing.replacing';
  static const editingFilterVideo = 'screenplay.editing.filterVideo';
  static const editingFilterImage = 'screenplay.editing.filterImage';
  static const editingFilterAudio = 'screenplay.editing.filterAudio';
  static const editingAdoptedSegments = 'screenplay.editing.adoptedSegments';
  static const editingNotAdopted = 'screenplay.editing.notAdopted';
  static const editingOtherVideos = 'screenplay.editing.otherVideos';
  static const editingDragHint = 'screenplay.editing.dragHint';
  static const editingPreparing = 'screenplay.editing.preparing';
  static const editingEnd = 'screenplay.editing.end';
  static const editingPreviousCut = 'screenplay.editing.previousCut';
  static const editingNextCut = 'screenplay.editing.nextCut';
  static const editingExportFile = 'screenplay.editing.exportFile';
  static const editingExportPictureDetail =
      'screenplay.editing.exportPictureDetail';
  static const editingExportSubtitles = 'screenplay.editing.exportSubtitles';
  static const editingExportSubtitlesSrt =
      'screenplay.editing.exportSubtitlesSrt';
  static const editingSubtitlesBurn = 'screenplay.editing.subtitlesBurn';
  static const editingSubtitlesSrt = 'screenplay.editing.subtitlesSrt';
  static const editingSubtitlesNone = 'screenplay.editing.subtitlesNone';
  static const editingSound = 'screenplay.editing.sound';
  static const editingExportSound = 'screenplay.editing.exportSound';
  static const editingExportMuted = 'screenplay.editing.exportMuted';
  static const editingExportHidden = 'screenplay.editing.exportHidden';
  static const editingStepVerify = 'screenplay.editing.stepVerify';
  static const editingStepRender = 'screenplay.editing.stepRender';
  static const editingStepAssemble = 'screenplay.editing.stepAssemble';
  static const editingStepValidate = 'screenplay.editing.stepValidate';
  static const editingExportLocal = 'screenplay.editing.exportLocal';
  static const editingExported = 'screenplay.editing.exported';
  static const editingExportedSrt = 'screenplay.editing.exportedSrt';
  static const editingExportTitle = 'screenplay.editing.exportTitle';
  static const editingExportByTimeline = 'screenplay.editing.exportByTimeline';
  static const editingExporting = 'screenplay.editing.exporting';
  static const editingCancelExport = 'screenplay.editing.cancelExport';
  static const editingImportAdopted = 'screenplay.editing.importAdopted';
  static const editingImported = 'screenplay.editing.imported';
  static const editingImportedSkipped = 'screenplay.editing.importedSkipped';
  static const editingSpecHint = 'screenplay.editing.specHint';
  static const editingResizeTimeline = 'screenplay.editing.resizeTimeline';
  // ── common ────────────────────────────────────────
  static const commonMoveUp = 'common.move_up';
  static const commonMoveDown = 'common.move_down';
  static const commonAdd = 'common.add';
  static const commonAi = 'common.ai';
  static const commonImport = 'common.import';
  static const commonExport = 'common.export';
  static const commonPlay = 'common.play';
  static const commonCancel = 'common.cancel';
  static const commonChoose = 'common.choose';
  static const commonChangeCreate = 'common.change_create';
  static const commonChangeRewrite = 'common.change_rewrite';
  static const commonChangeExpand = 'common.change_expand';
  static const commonChangeTrim = 'common.change_trim';
  static const commonChapterNumber = 'common.chapter_number';
  static const commonClose = 'common.close';
  static const commonCollapse = 'common.collapse';
  static const commonCollapseSidebar = 'common.collapse_sidebar';
  static const commonConfirm = 'common.confirm';
  static const commonContent = 'common.content';
  static const commonContinue = 'common.continue';
  static const commonContinueInBackground = 'common.continue_in_background';
  static const commonCopy = 'common.copy';
  static const commonCopied = 'common.copied';
  static const commonCover = 'common.cover';
  static const commonRequired = 'common.required';
  static const commonCreate = 'common.create';
  static const commonCreating = 'common.creating';
  static const commonCut = 'common.cut';
  static const commonDelete = 'common.delete';
  static const commonDeleteFailed = 'common.delete_failed';
  static const commonLoadFailed = 'common.load_failed';
  static const commonRetry = 'common.retry';
  static const commonDeleted = 'common.deleted';
  static const commonDescription = 'common.description';
  static const commonBack = 'common.back';
  static const commonDiscardChanges = 'common.discard_changes';
  static const commonDiscard = 'common.discard';
  static const commonDuplicateTitleIn = 'common.duplicate_title_in';
  static const commonNameHasPathChar = 'common.name_has_path_char';
  static const commonEdit = 'common.edit';
  static const commonExpand = 'common.expand';
  static const commonExpandSidebar = 'common.expand_sidebar';
  static const commonGender = 'common.gender';
  static const commonHourSuffix = 'common.hour_suffix';
  static const commonItemUnit = 'common.item_unit';
  static const commonMinuteSuffix = 'common.minute_suffix';
  static const commonMoreActions = 'common.more_actions';
  static const commonName = 'common.name';
  static const commonNameAssistant = 'common.name_assistant';
  static const commonNewline = 'common.newline';
  static const commonNoCoverSelected = 'common.no_cover_selected';
  static const commonNoDescription = 'common.no_description';
  static const commonOutline = 'common.outline';
  static const commonPaste = 'common.paste';
  static const commonPause = 'common.pause';
  static const commonPayoff = 'common.payoff';
  static const commonReadOnly = 'common.read_only';
  static const commonRemove = 'common.remove';
  static const commonRename = 'common.rename';
  static const commonGenerate = 'common.generate';
  static const productionImageMethod = 'production.imageMethod';
  static const productionImagePresets = 'production.imagePresets';
  static const productionGridPresets = 'production.gridPresets';
  static const productionImagePresetGroups = 'production.imagePresetGroups';
  static const productionImageMethodPrompt = 'production.imageMethodPrompt';
  static const productionGroupImagesOnly = 'production.groupImagesOnly';
  static const productionGridSplit = 'production.gridSplit';
  static const productionGridCustom = 'production.gridCustom';
  static const productionGridCapacity = 'production.gridCapacity';
  static const productionGridSelected = 'production.gridSelected';
  static const productionGridCreate = 'production.gridCreate';
  static const productionGridUpscaleRejected = 'production.gridUpscaleRejected';
  static const productionGridUpscale = 'production.gridUpscale';
  static const productionGridUpscaleUnsupported =
      'production.gridUpscaleUnsupported';
  static const productionGridSelectRequired = 'production.gridSelectRequired';
  static const commonClear = 'common.clear';
  static const productionGroupNumbered = 'production.groupNumbered';
  static const productionGroupClearConfirm = 'production.groupClearConfirm';
  static const productionGroupAi = 'production.groupAi';
  static const productionGroupStitch = 'production.groupStitch';
  static const productionSelectionDeleteConfirm =
      'production.selectionDeleteConfirm';
  static const productionGroupReferenceCount = 'production.groupReferenceCount';
  static const productionGroupReferenceImage = 'production.groupReferenceImage';
  static const productionGroupReferenceVideo = 'production.groupReferenceVideo';
  static const productionCertify = 'production.certify';
  static const productionCertifyWith = 'production.certifyWith';
  static const productionCertifyUnconfigured = 'production.certifyUnconfigured';
  static const productionCertifyProcessing = 'production.certifyProcessing';
  static const productionCertifyActive = 'production.certifyActive';
  static const productionCertifyFailed = 'production.certifyFailed';
  static const productionCertifyErrorFormat = 'production.certifyErrorFormat';
  static const productionCertifyErrorSize = 'production.certifyErrorSize';
  static const productionCertifyErrorDimensions =
      'production.certifyErrorDimensions';
  static const productionCertifyErrorRatio = 'production.certifyErrorRatio';
  static const productionCertifyErrorConfiguration =
      'production.certifyErrorConfiguration';
  static const productionCertifyErrorRequest = 'production.certifyErrorRequest';
  static const productionGroupStoryboard = 'production.groupStoryboard';
  static const productionGroupFree = 'production.groupFree';
  static const productionGroupCount = 'production.groupCount';
  static const productionGroupToFree = 'production.groupToFree';
  static const productionGroupToStoryboard = 'production.groupToStoryboard';
  static const productionGroupUngroup = 'production.groupUngroup';
  static const productionGroupDeleteConfirm = 'production.groupDeleteConfirm';
  static const productionViewViewComposition = 'production.viewComposition';
  static const productionViewCamera = 'production.camera';
  static const productionViewLight = 'production.light';
  static const productionViewPanoramaGenerate = 'production.panoramaGenerate';
  static const productionViewPanoramaPreview = 'production.panoramaPreview';
  static const productionViewImageRequired = 'production.imageRequired';
  static const productionViewPanoramaModelRequired =
      'production.panoramaModelRequired';
  static const productionViewImageModelRequired =
      'production.imageModelRequired';
  static const productionViewYaw = 'production.yaw';
  static const productionViewPitch = 'production.pitch';
  static const productionViewFraming = 'production.framing';
  static const productionViewDirection = 'production.direction';
  static const productionViewBrightness = 'production.brightness';
  static const productionViewTexture = 'production.texture';
  static const productionViewTemperature = 'production.temperature';
  static const productionViewDescription = 'production.description';
  static const productionViewPanoramaExit = 'production.panoramaExit';
  static const productionViewPanoramaReset = 'production.panoramaReset';
  static const productionViewPanoramaGrid = 'production.panoramaGrid';
  static const productionViewPanoramaFullscreen =
      'production.panoramaFullscreen';
  static const productionViewPanoramaKeys = 'production.panoramaKeys';
  static const productionViewPanoramaError = 'production.panoramaError';
  static const productionViewPanoramaSaveError = 'production.panoramaSaveError';
  static const productionViewPanoramaQuality = 'production.panoramaQuality';
  static const productionViewPanoramaHud = 'production.panoramaHud';
  static const productionViewPanoramaCaptureCurrent =
      'production.panoramaCaptureCurrent';
  static const productionViewPanoramaCaptureFour =
      'production.panoramaCaptureFour';
  static const productionViewPanoramaCurrent = 'production.panoramaCurrent';
  static const productionViewPanoramaFront = 'production.panoramaFront';
  static const productionViewPanoramaRight = 'production.panoramaRight';
  static const productionViewPanoramaBack = 'production.panoramaBack';
  static const productionViewPanoramaLeft = 'production.panoramaLeft';
  static const productionViewPanoramaCaptureTitle =
      'production.panoramaCaptureTitle';
  static const productionViewPanoramaCaptured = 'production.panoramaCaptured';
  static const productionViewPanoramaCaptureFailed =
      'production.panoramaCaptureFailed';
  static const productionViewPanoramaFailure = 'production.panoramaFailure';
  static const productionViewOptions = 'production.options';
  static const commonAdvancedOptions = 'common.advanced_options';
  static const commonReset = 'common.reset';
  static const commonRole = 'common.role';
  static const commonRootDirectory = 'common.root_directory';
  static const commonSave = 'common.save';
  static const commonSaveFailed = 'common.save_failed';
  static const commonDone = 'common.done';
  static const commonSaved = 'common.saved';
  static const commonSaving = 'common.saving';
  static const commonSearch = 'common.search';
  static const commonSearchCharacters = 'common.search_characters';
  static const commonSearchLocations = 'common.search_locations';
  static const commonSelectAll = 'common.select_all';
  static const commonClearSelection = 'common.clear_selection';
  static const commonNoResults = 'common.no_results';
  static const commonFilterAll = 'common.filter_all';
  static const commonNone = 'common.none';
  static const commonSelectedCountFmt = 'common.selected_count_fmt';
  static const commonSelectImage = 'common.select_image';
  static const commonSetup = 'common.setup';
  static const commonStatus = 'common.status';
  static const commonStop = 'common.stop';
  static const commonSummary = 'common.summary';
  static const commonTags = 'common.tags';
  static const commonThisFolder = 'common.this_folder';
  static const commonTitle = 'common.title';
  static const commonType = 'common.type';
  static const commonUnsaved = 'common.unsaved';
  static const commonUntitled = 'common.untitled';
  static const commonUntitledNovel = 'common.untitled_novel';
  static const commonPosition = 'common.position';
  static const commonUpgradeNow = 'common.upgrade_now';
  // ── condition ────────────────────────────────────────
  static const conditionAddCompare = 'condition.add_compare';
  static const conditionAddGroup = 'condition.add_group';
  static const conditionAllItems = 'condition.all_items';
  static const conditionAnd = 'condition.and';
  static const conditionAnyGroups = 'condition.any_groups';
  static const conditionOr = 'condition.or';
  static const conditionGroupTitle = 'condition.group_title';
  static const conditionHint = 'condition.hint';
  static const conditionLeft = 'condition.left';
  static const conditionOperator = 'condition.operator';
  static const conditionOperatorContains = 'condition.operator.contains';
  static const conditionOperatorEndsWith = 'condition.operator.ends_with';
  static const conditionOperatorEq = 'condition.operator.eq';
  static const conditionOperatorGt = 'condition.operator.gt';
  static const conditionOperatorGte = 'condition.operator.gte';
  static const conditionOperatorIsEmpty = 'condition.operator.is_empty';
  static const conditionOperatorIsNotEmpty = 'condition.operator.is_not_empty';
  static const conditionOperatorLt = 'condition.operator.lt';
  static const conditionOperatorLte = 'condition.operator.lte';
  static const conditionOperatorNeq = 'condition.operator.neq';
  static const conditionOperatorStartsWith = 'condition.operator.starts_with';
  static const conditionOperatorUnknown = 'condition.operator.unknown';
  static const conditionRight = 'condition.right';
  // ── connection ────────────────────────────────────────
  static const connectionTypeAdjacent = 'connection.type.adjacent';
  static const connectionTypePathTo = 'connection.type.path_to';
  // ── council ────────────────────────────────────────
  static const councilAddRound = 'council.add_round';
  static const councilCharacterAnalystDesc = 'council.character_analyst.desc';
  static const councilCharacterAnalystName = 'council.character_analyst.name';
  static const councilConflictDesignerDesc = 'council.conflict_designer.desc';
  static const councilConflictDesignerName = 'council.conflict_designer.name';
  static const councilCopyDiscussion = 'council.copy_discussion';
  static const councilCustomModel = 'council.custom_model';
  static const councilDefaultModel = 'council.default_model';
  static const councilDefaultTitle = 'council.default_title';
  static const councilDiscussing = 'council.discussing';
  static const councilDiscussionInProgress = 'council.discussion_in_progress';
  static const councilDiscussionRounds = 'council.discussion_rounds';
  static const councilNewDiscussion = 'council.new_discussion';
  static const councilPacingExpertDesc = 'council.pacing_expert.desc';
  static const councilPacingExpertName = 'council.pacing_expert.name';
  static const councilParticipantNameLabel = 'council.participant_name_label';
  static const councilParticipantPromptLabel =
      'council.participant_prompt_label';
  static const councilParticipantsCountFmt = 'council.participants_count_fmt';
  static const councilPhaseCancelled = 'council.phase_cancelled';
  static const councilPhaseCompletedFmt = 'council.phase_completed_fmt';
  static const councilPhaseDiscussingFmt = 'council.phase_discussing_fmt';
  static const councilPhaseError = 'council.phase_error';
  static const councilPhasePreparing = 'council.phase_preparing';
  static const councilPhaseSummarizing = 'council.phase_summarizing';
  static const councilPlotArchitectDesc = 'council.plot_architect.desc';
  static const councilPlotArchitectName = 'council.plot_architect.name';
  static const councilPreviousSummary = 'council.previous_summary';
  static const councilPreviousSummaryThroughRound =
      'council.previous_summary_through_round';
  static const councilMessageRegenerate = 'council.message_regenerate';
  static const councilReplay = 'council.replay';
  static const councilRoundLabelFmt = 'council.round_label_fmt';
  static const councilSelectParticipants = 'council.select_participants';
  static const councilSessionTitleFmt = 'council.session_title_fmt';
  static const councilSpeakFmt = 'council.speak_fmt';
  static const councilSpeakingFmt = 'council.speaking_fmt';
  static const councilStart = 'council.start';
  static const councilSummarizingState = 'council.summarizing_state';
  static const councilSummaryGenerating = 'council.summary_generating';
  static const councilSummaryTitle = 'council.summary_title';
  static const councilThemeGuardianDesc = 'council.theme_guardian.desc';
  static const councilThemeGuardianName = 'council.theme_guardian.name';
  static const councilTopic = 'council.topic';
  static const councilTopicHint = 'council.topic_hint';
  static const councilUserInputHint = 'council.user_input_hint';
  static const councilUserSpeakerLabel = 'council.user_speaker_label';
  static const councilUpdateSummary = 'council.update_summary';
  static const councilWorldBuilderDesc = 'council.world_builder.desc';
  static const councilWorldBuilderName = 'council.world_builder.name';
  // ── assets ────────────────────────────────────────
  static const assetExportFieldKeys = <String, String>{
    'identity': 'assets.export_field_identity',
    'age': 'assets.export_field_age',
    'biography': 'assets.export_field_biography',
    'emotion': 'assets.export_field_emotion',
    'personality': 'assets.export_field_personality',
    'motivation': 'assets.export_field_motivation',
    'arc': 'assets.export_field_arc',
  };

  static const productionStyleCustom = 'screenplay.production_style_custom';
  static const productionStyleCustomPrompt =
      'screenplay.production_style_custom_prompt';
  static const productionStyleSearch = 'screenplay.production_style_search';
  static const productionStyleLiveAction =
      'screenplay.production_style_live_action';
  static const productionStyleTwoD = 'screenplay.production_style_two_d';
  static const productionStyleThreeD = 'screenplay.production_style_three_d';
  static const productionStyleInherit = 'screenplay.production_style_inherit';
  static const productionStyleNone = 'screenplay.production_style_none';
  static const productionStyleMissing = 'screenplay.production_style_missing';
  static const productionStyleScreenplayTag =
      'screenplay.production_style_screenplay_tag';
  static const productionStyleScreenplayHint =
      'screenplay.production_style_screenplay_hint';
  static const productionStyleClear = 'screenplay.production_style_clear';
  static const productionStyleInheritHint =
      'screenplay.production_style_inherit_hint';
  static const productionStyleOwnHint = 'screenplay.production_style_own_hint';
  static const productionStyleBefore = 'screenplay.production_style_before';
  static const productionStyleAfter = 'screenplay.production_style_after';
  static const productionStyleDelete = 'screenplay.production_style_delete';
  static const productionSpecResolution =
      'screenplay.production_spec_resolution';
  static const productionSpecRatio = 'screenplay.production_spec_ratio';
  static const productionSpecNote = 'screenplay.production_spec_note';
  static const productionSpecTooltip = 'screenplay.production_spec_tooltip';
  static const productionAddInputHint = 'screenplay.production_add_input_hint';
  static const productionPickLibrary = 'screenplay.production_pick_library';
  static const productionResultsTitle = 'screenplay.production_results_title';
  static const productionResultsSummary =
      'screenplay.production_results_summary';
  static const productionResultsEmpty = 'screenplay.production_results_empty';
  static const productionResultsRun = 'screenplay.production_results_run';
  static const productionResultsSwitch = 'screenplay.production_results_switch';
  static const productionResultsInUse = 'screenplay.production_results_in_use';
  static const productionResultsPickVideo =
      'screenplay.production_results_pick_video';
  static const productionResultsPickImage =
      'screenplay.production_results_pick_image';
  static const productionUsedAsReference =
      'screenplay.production_used_as_reference';
  static const productionUsedAsReferenceHint =
      'screenplay.production_used_as_reference_hint';
  static const productionUsedAsReferenceEmpty =
      'screenplay.production_used_as_reference_empty';
  static const assetBoneHips = 'assets.bone_hips';
  static const assetBoneSpine = 'assets.bone_spine';
  static const assetBoneChest = 'assets.bone_chest';
  static const assetBoneNeck = 'assets.bone_neck';
  static const assetBoneHead = 'assets.bone_head';
  static const assetBoneLeftUpperArm = 'assets.bone_leftUpperArm';
  static const assetBoneLeftLowerArm = 'assets.bone_leftLowerArm';
  static const assetBoneLeftHand = 'assets.bone_leftHand';
  static const assetBoneRightUpperArm = 'assets.bone_rightUpperArm';
  static const assetBoneRightLowerArm = 'assets.bone_rightLowerArm';
  static const assetBoneRightHand = 'assets.bone_rightHand';
  static const assetBoneLeftUpperLeg = 'assets.bone_leftUpperLeg';
  static const assetBoneLeftLowerLeg = 'assets.bone_leftLowerLeg';
  static const assetBoneLeftFoot = 'assets.bone_leftFoot';
  static const assetBoneRightUpperLeg = 'assets.bone_rightUpperLeg';
  static const assetBoneRightLowerLeg = 'assets.bone_rightLowerLeg';
  static const assetBoneRightFoot = 'assets.bone_rightFoot';
  static const mediaTitle = 'assets.media_title';
  static const mediaImages = 'assets.media_images';
  static const mediaVideos = 'assets.media_videos';
  static const mediaAudio = 'assets.media_audio';
  static const mediaEmpty = 'assets.media_empty';
  static const mediaImportFailed = 'assets.media_import_failed';
  static const mediaLoadFailed = 'assets.media_load_failed';
  static const mediaPreviewFailed = 'assets.media_preview_failed';
  static const mediaExportFailed = 'assets.media_export_failed';
  static const mediaDeleteConfirm = 'assets.media_delete_confirm';
  // Detail page
  // ── diff ────────────────────────────────────────
  static const diffReviewAppliedCount = 'diff.review_applied_count';
  static const diffReviewMarkedCount = 'diff.review_marked_count';
  static const diffReviewRestoreLine = 'diff.review_restore_line';
  static const diffReviewRevertLine = 'diff.review_revert_line';
  static const diffUnchangedHidden = 'diff.unchanged_hidden';
  // ── editor ────────────────────────────────────────
  static const editorAgentEditingBackBlocked =
      'editor.agent_editing_back_blocked';
  static const editorAiProcessingExitMessage =
      'editor.ai_processing_exit_message';
  static const editorAiProcessingExitTitle = 'editor.ai_processing_exit_title';
  static const editorApplyGeneratedCover = 'editor.apply_generated_cover';
  static const editorBackToLibrary = 'editor.back_to_library';
  static const editorCoverExtraHint = 'editor.cover_extra_hint';
  static const editorCoverExtraRequirements = 'editor.cover_extra_requirements';
  static const editorCoverGenerationFailed = 'editor.cover_generation_failed';
  static const editorCoverPrompt = 'editor.cover_prompt';
  static const editorCoverPromptHint = 'editor.cover_prompt_hint';
  static const editorCoverStartCraft = 'editor.cover_start_craft';
  static const editorCoverGenerating = 'editor.cover_generating';
  static const editorCoverStop = 'editor.cover_stop';
  static const mapEditorAiGeneratedNotice = 'map_editor.ai_generated_notice';
  static const mapEditorAgentAsk = 'map_editor.agent_ask';
  static const mapEditorAgentDraftApply = 'map_editor.agent_draft_apply';
  static const mapEditorAgentDraftDismiss = 'map_editor.agent_draft_dismiss';
  static const mapEditorAgentDraftNote = 'map_editor.agent_draft_note';
  static const mapEditorAgentDraftResolveFirst =
      'map_editor.agent_draft_resolve_first';
  static const mapEditorAgentDraftTitle = 'map_editor.agent_draft_title';
  static const mapEditorAgentHandoffLabel = 'map_editor.agent_handoff_label';
  static const mapEditorQuality = 'map_editor.quality';
  static const mapEditorQualityLow = 'map_editor.quality_low';
  static const mapEditorQualityMedium = 'map_editor.quality_medium';
  static const mapEditorQualityHigh = 'map_editor.quality_high';
  static const editorCoverStopWarning = 'editor.cover_stop_warning';
  static const editorImageLibrary = 'editor.image_library';
  static const editorCoverStudio = 'editor.cover_studio';
  static const editorCoverStudioHint = 'editor.cover_studio_hint';
  static const editorCoverStyle = 'editor.cover_style';
  static const editorCoverStyleCardHint = 'editor.cover_style_card_hint';
  static const editorCoverStyleCinematic = 'editor.cover_style_cinematic';
  static const editorCoverStyleCustomHint = 'editor.cover_style_custom_hint';
  static const editorCoverStyleEastern = 'editor.cover_style_eastern';
  static const editorCoverStyleIllustration = 'editor.cover_style_illustration';
  static const editorCoverStyleMinimal = 'editor.cover_style_minimal';
  static const editorEditNovelInfo = 'editor.edit_novel_info';
  static const editorGenerateFourCovers = 'editor.generate_four_covers';
  static const editorGeneratedCoverApplied = 'editor.generated_cover_applied';
  static const editorGeneratedCoverReady = 'editor.generated_cover_ready';
  static const editorNovelLoadFailed = 'editor.novel_load_failed';
  static const editorNovelNotFound = 'editor.novel_not_found';
  static const editorNovelNotFoundHint = 'editor.novel_not_found_hint';
  static const editorOpenCoverStudio = 'editor.open_cover_studio';
  static const editorCoverNavLabel = 'editor.cover_nav_label';
  static const editorCoverGenerationRecords = 'editor.cover_generation_records';
  static const editorCoverDesigner = 'editor.cover_designer';
  static const editorCoverDesignerHint = 'editor.cover_designer_hint';
  static const editorCoverDesignerHintUnread =
      'editor.cover_designer_hint_unread';
  static const editorCoverReadNotes = 'editor.cover_read_notes';
  static const editorCoverReferences = 'editor.cover_references';
  static const editorCoverPalette = 'editor.cover_palette';
  static const editorCoverComposition = 'editor.cover_composition';
  static const editorCoverEmptyTitle = 'editor.cover_empty_title';
  static const editorCoverEmptyHint = 'editor.cover_empty_hint';
  static const editorCoverNew = 'editor.cover_new';
  static const editorCoverGenerateSimilar = 'editor.cover_generate_similar';
  static const editorCoverAdjustTitle = 'editor.cover_adjust_title';
  static const editorCoverZoomOut = 'editor.cover_zoom_out';
  static const editorCoverZoomIn = 'editor.cover_zoom_in';
  static const editorCoverSelectReference = 'editor.cover_select_reference';
  static const editorCoverReferenceDropHint =
      'editor.cover_reference_drop_hint';
  static const editorCoverReferenceUploadFile =
      'editor.cover_reference_upload_file';
  static const editorCoverReferenceAdd = 'editor.cover_reference_add';
  static const editorCoverReferenceCollapse = 'editor.cover_reference_collapse';
  static const editorCoverReferenceCount = 'editor.cover_reference_count';
  static const editorCoverBatchCount = 'editor.cover_batch_count';
  static const editorCoverScheme = 'editor.cover_scheme';
  static const editorCoverWork = 'editor.cover_work';
  static const editorCoverWorkChapters = 'editor.cover_work_chapters';
  static const editorCoverWorkNoCover = 'editor.cover_work_no_cover';
  static const editorCoverReferenceOrdinal = 'editor.cover_reference_ordinal';
  static const editorCoverReferenceUsageHint =
      'editor.cover_reference_usage_hint';
  static const editorCoverCanvasSettings = 'editor.cover_canvas_settings';
  static const editorCoverExport = 'editor.cover_export';
  static const editorCoverStyleInk = 'editor.cover_style_ink';
  static const editorCoverStylePrint = 'editor.cover_style_print';
  static const editorCoverStyleMinimalText = 'editor.cover_style_minimal_text';
  static const editorCoverStylePhotoreal = 'editor.cover_style_photoreal';
  static const editorCoverStyleHandDrawn = 'editor.cover_style_hand_drawn';
  static const editorCoverPaletteInk = 'editor.cover_palette_ink';
  static const editorCoverPaletteBrass = 'editor.cover_palette_brass';
  static const editorCoverPaletteNight = 'editor.cover_palette_night';
  static const editorCoverPaletteCinnabar = 'editor.cover_palette_cinnabar';
  static const editorCoverPaletteGrey = 'editor.cover_palette_grey';
  static const editorCoverCompositionCenter = 'editor.cover_composition_center';
  static const editorCoverCompositionThirds = 'editor.cover_composition_thirds';
  static const editorCoverCompositionNegative =
      'editor.cover_composition_negative';
  static const editorCoverCompositionSymmetric =
      'editor.cover_composition_symmetric';
  static const editorCoverQuality = 'editor.cover_quality';
  static const editorCoverQualityAuto = 'editor.cover_quality_auto';
  static const editorCoverQualityLow = 'editor.cover_quality_low';
  static const editorCoverQualityMedium = 'editor.cover_quality_medium';
  static const editorCoverQualityHigh = 'editor.cover_quality_high';
  static const editorCoverResolution = 'editor.cover_resolution';
  static const editorCoverRatio = 'editor.cover_ratio';
  static const editorCoverAdvanced = 'editor.cover_advanced';
  static const editorCoverInspiration = 'editor.cover_inspiration';
  static const editorCoverAppendHint = 'editor.cover_append_hint';
  static const editorCoverAppendSynopsis = 'editor.cover_append_synopsis';
  static const editorCoverBrief = 'editor.cover_brief';
  static const editorCoverBriefReread = 'editor.cover_brief_reread';
  static const editorCoverBriefRead = 'editor.cover_brief_read';
  static const editorCoverBriefBlankNote = 'editor.cover_brief_blank_note';
  static const editorCoverBriefReading = 'editor.cover_brief_reading';
  static const editorCoverBriefCategory = 'editor.cover_brief_category';
  static const editorCoverBriefTemperature = 'editor.cover_brief_temperature';
  static const editorCoverBriefFigure = 'editor.cover_brief_figure';
  static const editorCoverBriefEra = 'editor.cover_brief_era';
  static const editorCoverBriefFooter = 'editor.cover_brief_footer';
  static const editorCoverBriefStale = 'editor.cover_brief_stale';
  static const editorCoverBriefFailed = 'editor.cover_brief_failed';
  static const editorCoverBriefDone = 'editor.cover_brief_done';
  static const editorCoverErrorModerationTitle =
      'editor.cover_error_moderation_title';
  static const editorCoverErrorModerationBody =
      'editor.cover_error_moderation_body';
  static const editorCoverErrorRateLimitTitle =
      'editor.cover_error_rate_limit_title';
  static const editorCoverErrorRateLimitBody =
      'editor.cover_error_rate_limit_body';
  static const editorCoverErrorAuthTitle = 'editor.cover_error_auth_title';
  static const editorCoverErrorAuthBody = 'editor.cover_error_auth_body';
  static const editorCoverErrorSizeTitle = 'editor.cover_error_size_title';
  static const editorCoverErrorSizeBody = 'editor.cover_error_size_body';
  static const editorCoverErrorParamTitle = 'editor.cover_error_param_title';
  static const editorCoverErrorParamBody = 'editor.cover_error_param_body';
  static const editorCoverErrorCreditTitle = 'editor.cover_error_credit_title';
  static const editorCoverErrorCreditBody = 'editor.cover_error_credit_body';
  static const editorCoverErrorModelForbiddenTitle =
      'editor.cover_error_model_forbidden_title';
  static const editorCoverErrorModelForbiddenBody =
      'editor.cover_error_model_forbidden_body';
  static const editorCoverErrorUnknownTitle =
      'editor.cover_error_unknown_title';
  static const editorCoverErrorUnknownBody = 'editor.cover_error_unknown_body';
  static const editorCoverErrorCanceledTitle =
      'editor.cover_error_canceled_title';
  static const editorCoverErrorCanceledBody =
      'editor.cover_error_canceled_body';
  static const editorCoverBatchStatusRunning =
      'editor.cover_batch_status_running';
  static const editorCoverBatchStatusStopping =
      'editor.cover_batch_status_stopping';
  static const editorCoverBatchStatusPartial =
      'editor.cover_batch_status_partial';
  static const editorCoverBatchStatusCanceled =
      'editor.cover_batch_status_canceled';
  static const editorCoverBatchStatusFailed =
      'editor.cover_batch_status_failed';
  static const editorCoverBatchReuse = 'editor.cover_batch_reuse';
  static const editorCoverRecordsBlank = 'editor.cover_records_blank';
  static const editorCoverReferenceLimitAlert =
      'editor.cover_reference_limit_alert';
  static const editorCoverReferenceDropped = 'editor.cover_reference_dropped';
  static const editorCoverReferenceLibrary = 'editor.cover_reference_library';
  static const editorAssetFilterAll = 'editor.asset_filter_all';
  static const editorAssetFilterMaps = 'editor.asset_filter_maps';
  static const editorAssetFilterCovers = 'editor.asset_filter_covers';
  static const editorAssetFilterCharacters = 'editor.asset_filter_characters';
  static const editorAssetFilterUploads = 'editor.asset_filter_uploads';
  static const editorCoverRework = 'editor.cover_rework';
  static const editorCoverSeedFrom = 'editor.cover_seed_from';
  static const editorCoverApply = 'editor.cover_apply';
  static const editorCoverApplied = 'editor.cover_applied';
  static const editorCoverZoomFit = 'editor.cover_zoom_fit';
  static const editorCoverRatioMeta = 'editor.cover_ratio_meta';
  static const editorCoverRatioMetaTooltip = 'editor.cover_ratio_meta_tooltip';
  static const editorCoverRatioUsePortrait = 'editor.cover_ratio_use_portrait';
  static const editorCoverRatioUseLandscape =
      'editor.cover_ratio_use_landscape';
  static const editorCoverRatioUseSquare = 'editor.cover_ratio_use_square';
  static const editorCoverSchemeLabel = 'editor.cover_scheme_label';
  static const editorCoverStageGenerating = 'editor.cover_stage_generating';
  static const editorCoverStageStopping = 'editor.cover_stage_stopping';
  static const editorCoverStageReworking = 'editor.cover_stage_reworking';
  static const editorCoverStageReworkCaption =
      'editor.cover_stage_rework_caption';
  static const editorCoverStageStoppingCaption =
      'editor.cover_stage_stopping_caption';
  static const editorCoverStageFailedCaption =
      'editor.cover_stage_failed_caption';
  static const editorCoverStageGeneratingCaption =
      'editor.cover_stage_generating_caption';
  static const editorCoverEmptyBody = 'editor.cover_empty_body';
  static const editorCoverEmptyBodyMobile = 'editor.cover_empty_body_mobile';
  static const editorCoverGenerateCount = 'editor.cover_generate_count';
  static const editorCoverPromptPreview = 'editor.cover_prompt_preview';
  static const editorCoverPromptView = 'editor.cover_prompt_view';
  static const editorCoverAiGeneratedNotice =
      'editor.cover_ai_generated_notice';
  static const editorCoverCustomStyleRequired =
      'editor.cover_custom_style_required';
  static const editorCoverStopProgress = 'editor.cover_stop_progress';
  static const editorCoverStoppingProgress = 'editor.cover_stopping_progress';
  static const editorCoverStopNote = 'editor.cover_stop_note';
  static const editorCoverStoppingNote = 'editor.cover_stopping_note';
  static const editorCoverToastGenerated = 'editor.cover_toast_generated';
  static const editorCoverToastPartial = 'editor.cover_toast_partial';
  static const editorCoverToastCanceled = 'editor.cover_toast_canceled';
  static const editorCoverToastFailed = 'editor.cover_toast_failed';
  static const editorCoverToastStopped = 'editor.cover_toast_stopped';
  static const editorCoverToastReworked = 'editor.cover_toast_reworked';
  static const editorCoverToastReworkFailed =
      'editor.cover_toast_rework_failed';
  static const editorCoverToastApplied = 'editor.cover_toast_applied';
  static const editorCoverToastSeedFrom = 'editor.cover_toast_seed_from';
  static const editorCoverReadNoteImagery = 'editor.cover_read_note_imagery';
  static const editorCoverReadNoteTitle = 'editor.cover_read_note_title';
  static const editorCoverBatchFallback = 'editor.cover_batch_fallback';
  static const editorCoverMissingImage = 'editor.cover_missing_image';
  static const editorPasteTooLarge = 'editor.paste_too_large';
  static const editorHeadingLevelTitle = 'editor.heading_level_title';
  static const editorFind = 'editor.find';
  static const editorFindNext = 'editor.find_next';
  static const editorFindPrevious = 'editor.find_previous';
  static const editorFindReplace = 'editor.find_replace';
  static const editorMatchCase = 'editor.match_case';
  static const editorRemoveCover = 'editor.remove_cover';
  static const editorReplaceCover = 'editor.replace_cover';
  static const editorReplaceAll = 'editor.replace_all';
  static const editorReplaceOne = 'editor.replace_one';
  static const editorReplaceWith = 'editor.replace_with';
  static const editorSaveNovelFailed = 'editor.save_novel_failed';
  static const editorSubagentUnsavedChanges = 'editor.subagent_unsaved_changes';
  static const editorUnsavedChangesTitle = 'editor.unsaved_changes_title';
  static const editorUnsavedChangesMessage = 'editor.unsaved_changes_message';
  static const editorUploadCover = 'editor.upload_cover';
  static const editorWorkspaceLoadFailed = 'editor.workspace_load_failed';
  // ── entity ────────────────────────────────────────
  static const entityTypeChapter = 'entity.type.chapter';
  static const entityTypeCharacter = 'entity.type.character';
  static const entityTypeCreature = 'entity.type.creature';
  static const entityTypeFaction = 'entity.type.faction';
  static const entityTypeForeshadowing = 'entity.type.foreshadowing';
  static const entityTypeItem = 'entity.type.item';
  static const entityTypeLocation = 'entity.type.location';
  static const entityTypeSkill = 'entity.type.skill';
  static const entityTypeUnknown = 'entity.type.unknown';
  static const entitySubjectLocations = 'entity.subject.locations';
  static const entitySubjectCharactersEmpty = 'entity.subject.characters_empty';
  static const entitySubjectLocationsEmpty = 'entity.subject.locations_empty';
  static const entitySubjectCompendiumEmpty = 'entity.subject.compendium_empty';
  static const entitySubjectPhotoCount = 'entity.subject.photo_count';
  static const entityGraphBrowseEntities = 'entity_graph.browse_entities';
  // ── entity_graph ────────────────────────────────────────
  static const entityGraphNoData = 'entity_graph.no_data';
  static const entityGraphUntitledChapter = 'entity_graph.untitled_chapter';
  static const entityGraphTitle = 'entity_graph.title';
  static const entityGraphTabEntities = 'entity_graph.tab_entities';
  static const entityGraphTabRelationTypes = 'entity_graph.tab_relation_types';
  static const entityGraphAllEntities = 'entity_graph.all_entities';
  static const entityGraphSearchPlaceholder = 'entity_graph.search_placeholder';
  static const entityGraphFilterAll = 'entity_graph.filter_all';
  static const entityGraphFilterEntityTypes =
      'entity_graph.filter_entity_types';
  static const entityGraphViewGraph = 'entity_graph.view_graph';
  static const entityGraphDisplayDepth = 'entity_graph.display_depth';
  static const entityGraphDepthLayers = 'entity_graph.depth_layers';
  static const entityGraphCenterPlaceholder = 'entity_graph.center_placeholder';
  static const entityGraphRelationTypeAll = 'entity_graph.relation_type_all';
  static const entityGraphShowLabels = 'entity_graph.show_labels';
  static const entityGraphShowDirection = 'entity_graph.show_direction';
  static const entityGraphReset = 'entity_graph.reset';
  static const entityGraphExitFocus = 'entity_graph.exit_focus';
  static const entityGraphRelationsOf = 'entity_graph.relations_of';
  static const entityGraphTabAll = 'entity_graph.tab_all';
  static const entityGraphTabActive = 'entity_graph.tab_active';
  static const entityGraphTabPassive = 'entity_graph.tab_passive';
  static const entityGraphAddRelation = 'entity_graph.add_relation';
  static const entityGraphLoadError = 'entity_graph.load_error';
  static const entityGraphEvidenceChain = 'entity_graph.evidence_chain';
  static const entityGraphViewAll = 'entity_graph.view_all';
  static const entityGraphEstablishedAt = 'entity_graph.established_at';
  static const entityGraphEvidenceCount = 'entity_graph.evidence_count';
  static const entityGraphExpandAll = 'entity_graph.expand_all';
  static const entityGraphCollapseAll = 'entity_graph.collapse_all';
  static const entityGraphCoreCharacters = 'entity_graph.core_characters';
  static const entityGraphFamilies = 'entity_graph.families';
  static const entityGraphOrganizations = 'entity_graph.organizations';
  static const entityGraphCategoryKin = 'entity_graph.category_kin';
  static const entityGraphCategoryBond = 'entity_graph.category_bond';
  static const entityGraphCategoryLover = 'entity_graph.category_lover';
  static const entityGraphCategoryEnemy = 'entity_graph.category_enemy';
  static const entityGraphCategoryMaster = 'entity_graph.category_master';
  static const entityGraphCategoryFaction = 'entity_graph.category_faction';
  static const entityGraphCategoryItem = 'entity_graph.category_item';
  static const entityGraphCategorySkill = 'entity_graph.category_skill';
  static const entityGraphCategoryAlter = 'entity_graph.category_alter';
  static const entityGraphCategoryEvolve = 'entity_graph.category_evolve';
  static const entityGraphCategoryOther = 'entity_graph.category_other';
  static const entityGraphLegendTitle = 'entity_graph.legend_title';
  static const entityGraphOverviewTitle = 'entity_graph.overview_title';
  static const entityGraphRelationsUnit = 'entity_graph.relations_unit';
  static const entityGraphResetView = 'entity_graph.reset_view';
  static const entityGraphStatDirect = 'entity_graph.stat_direct';
  static const entityGraphStatIndirect = 'entity_graph.stat_indirect';
  static const entityGraphZoomIn = 'entity_graph.zoom_in';
  static const entityGraphZoomOut = 'entity_graph.zoom_out';
  static const entityGraphZoomFit = 'entity_graph.zoom_fit';
  static const entityGraphExportImage = 'entity_graph.export_image';
  static const entityGraphExportSuccess = 'entity_graph.export_success';
  static const entityGraphExportFailed = 'entity_graph.export_failed';
  static const entityGraphInspectorRelations =
      'entity_graph.inspector_relations';
  static const entityGraphInspectorDetails = 'entity_graph.inspector_details';
  static const entityGraphInspectorProfile = 'entity_graph.inspector_profile';
  static const entityGraphInspectorBasicAttrs =
      'entity_graph.inspector_basic_attrs';
  static const entityGraphInspectorRelationOverview =
      'entity_graph.inspector_relation_overview';
  static const entityGraphInspectorImportantRelations =
      'entity_graph.inspector_important_relations';
  static const entityGraphInspectorDirectRelations =
      'entity_graph.inspector_direct_relations';
  static const entityGraphInspectorIndirectRelations =
      'entity_graph.inspector_indirect_relations';
  static const entityGraphInspectorRelationType =
      'entity_graph.inspector_relation_type';
  static const entityGraphInspectorOriginName =
      'entity_graph.inspector_origin_name';
  static const entityGraphInspectorEvidenceSource =
      'entity_graph.inspector_evidence_source';
  // ── entity_search ────────────────────────────────────────
  static const entityGraphSearchEmpty = 'entity_search.empty';
  static const entitySearchHint = 'entity_search.hint';
  static const entitySearchLoadFailed = 'entity_search.load_failed';
  // ── floating_chat ────────────────────────────────────────
  static const floatingChatClear = 'floating_chat.clear';
  static const floatingChatClearConfirm = 'floating_chat.clear_confirm';
  static const floatingChatEmptyHint = 'floating_chat.empty_hint';
  static const floatingChatEmptySubHint = 'floating_chat.empty_sub_hint';
  static const floatingChatInitError = 'floating_chat.init_error';
  static const floatingChatInitializing = 'floating_chat.initializing';
  static const floatingChatMinimize = 'floating_chat.minimize';
  static const floatingChatNoProvider = 'floating_chat.no_provider';
  static const floatingChatPlaceholder = 'floating_chat.placeholder';
  static const floatingChatSend = 'floating_chat.send';
  static const floatingChatStop = 'floating_chat.stop';
  static const floatingChatTitle = 'floating_chat.title';
  // ── form ────────────────────────────────────────
  static const formDateAfter = 'form.date_after';
  static const formDateBefore = 'form.date_before';
  static const formInvalidEmail = 'form.invalid_email';
  static const formInvalidPattern = 'form.invalid_pattern';
  static const formInvalidPhone = 'form.invalid_phone';
  static const formMaxItems = 'form.max_items';
  static const formMaxLength = 'form.max_length';
  static const formMinItems = 'form.min_items';
  static const formMinLength = 'form.min_length';
  static const formRequired = 'form.required';
  // ── heuristic ────────────────────────────────────────
  // ── Heuristic Onboarding ──
  static const heuristicGoThere = 'heuristic.go_there';
  static const heuristicNotToday = 'heuristic.not_today';
  static const heuristicStopSuggestions = 'heuristic.stop_suggestions';
  static const heuristicDontShowAgain = 'heuristic.dont_show_again';
  // ── Heuristic Feature Metadata (for discovery banner) ──
  static const heuristicFeatureOverview = 'heuristic.feature.overview';
  static const heuristicFeatureOverviewDesc = 'heuristic.feature.overview_desc';
  static const heuristicFeatureChapters = 'heuristic.feature.chapters';
  static const heuristicFeatureChaptersDesc = 'heuristic.feature.chapters_desc';
  static const heuristicFeatureNovelDescription =
      'heuristic.feature.novel_description';
  static const heuristicFeatureNovelDescriptionDesc =
      'heuristic.feature.novel_description_desc';
  static const heuristicFeatureOutlines = 'heuristic.feature.outlines';
  static const heuristicFeatureOutlinesDesc = 'heuristic.feature.outlines_desc';
  static const heuristicFeatureCharacters = 'heuristic.feature.characters';
  static const heuristicFeatureCharactersDesc =
      'heuristic.feature.characters_desc';
  static const heuristicFeatureWorldbuilding =
      'heuristic.feature.worldbuilding';
  static const heuristicFeatureWorldbuildingDesc =
      'heuristic.feature.worldbuilding_desc';
  static const heuristicFeatureMaps = 'heuristic.feature.maps';
  static const heuristicFeatureMapsDesc = 'heuristic.feature.maps_desc';
  static const heuristicFeatureMaterials = 'heuristic.feature.materials';
  static const heuristicFeatureMaterialsDesc =
      'heuristic.feature.materials_desc';
  static const heuristicFeatureForeshadowings =
      'heuristic.feature.foreshadowings';
  static const heuristicFeatureForeshadowingsDesc =
      'heuristic.feature.foreshadowings_desc';
  static const heuristicFeatureFactions = 'heuristic.feature.factions';
  static const heuristicFeatureFactionsDesc = 'heuristic.feature.factions_desc';
  static const heuristicFeatureCreatures = 'heuristic.feature.creatures';
  static const heuristicFeatureCreaturesDesc =
      'heuristic.feature.creatures_desc';
  static const heuristicFeatureItems = 'heuristic.feature.items';
  static const heuristicFeatureItemsDesc = 'heuristic.feature.items_desc';
  static const heuristicFeatureSkills = 'heuristic.feature.skills';
  static const heuristicFeatureSkillsDesc = 'heuristic.feature.skills_desc';
  static const heuristicFeatureMemory = 'heuristic.feature.memory';
  static const heuristicFeatureMemoryDesc = 'heuristic.feature.memory_desc';
  static const heuristicFeatureEntityGraph = 'heuristic.feature.entity_graph';
  static const heuristicFeatureEntityGraphDesc =
      'heuristic.feature.entity_graph_desc';
  static const heuristicFeatureSearch = 'heuristic.feature.search';
  static const heuristicFeatureSearchDesc = 'heuristic.feature.search_desc';
  static const heuristicFeatureAiChat = 'heuristic.feature.ai_chat';
  static const heuristicFeatureAiChatDesc = 'heuristic.feature.ai_chat_desc';
  static const heuristicFeatureAiCouncil = 'heuristic.feature.ai_council';
  static const heuristicFeatureAiCouncilDesc =
      'heuristic.feature.ai_council_desc';
  static const heuristicFeatureAiMonologue = 'heuristic.feature.ai_monologue';
  static const heuristicFeatureAiMonologueDesc =
      'heuristic.feature.ai_monologue_desc';
  static const heuristicFeatureAiTheater = 'heuristic.feature.ai_theater';
  static const heuristicFeatureAiTheaterDesc =
      'heuristic.feature.ai_theater_desc';
  static const heuristicFeatureAiRoleplay = 'heuristic.feature.ai_roleplay';
  static const heuristicFeatureAiRoleplayDesc =
      'heuristic.feature.ai_roleplay_desc';
  static const heuristicFeatureAiCoverStudio =
      'heuristic.feature.ai_cover_studio';
  static const heuristicFeatureAiCoverStudioDesc =
      'heuristic.feature.ai_cover_studio_desc';
  static const heuristicFeatureAiStylePolish =
      'heuristic.feature.ai_style_polish';
  static const heuristicFeatureAiStylePolishDesc =
      'heuristic.feature.ai_style_polish_desc';
  static const heuristicFeatureAiReview = 'heuristic.feature.ai_review';
  static const heuristicFeatureAiReviewDesc =
      'heuristic.feature.ai_review_desc';
  static const heuristicFeatureAgentProfile = 'heuristic.feature.agent_profile';
  static const heuristicFeatureAgentProfileDesc =
      'heuristic.feature.agent_profile_desc';
  static const heuristicFeatureSubAgent = 'heuristic.feature.sub_agent';
  static const heuristicFeatureSubAgentDesc =
      'heuristic.feature.sub_agent_desc';
  // ── Chat Next Action (建议条壳文案与空态卡片) ──
  static const heuristicNextActionTitle = 'heuristic.next_action.title';
  static const heuristicNextActionGotoCouncil =
      'heuristic.next_action.goto_council';
  static const heuristicNextActionGotoCouncilSub =
      'heuristic.next_action.goto_council_sub';
  static const heuristicNextActionGotoTheater =
      'heuristic.next_action.goto_theater';
  static const heuristicNextActionGotoTheaterSub =
      'heuristic.next_action.goto_theater_sub';
  static const heuristicNextActionGotoCover =
      'heuristic.next_action.goto_cover';
  static const heuristicNextActionGotoCoverSub =
      'heuristic.next_action.goto_cover_sub';
  // ── history ────────────────────────────────────────
  static const historyCommitCount = 'history.commit_count';
  static const historyCommitDefaultMessage = 'history.commit_default_message';
  static const historyCommitMessageAcceptAiChange =
      'history.commit_message.accept_ai_change';
  static const historyCommitMessageAcceptAiChangeGroup =
      'history.commit_message.accept_ai_change_group';
  static const historyCommitMessageAcceptAllPendingAiChanges =
      'history.commit_message.accept_all_pending_ai_changes';
  static const historyCommitMessageAutoCommitAiChanges =
      'history.commit_message.auto_commit_ai_changes';
  static const historyCommitMessageManualChapterSave =
      'history.commit_message.manual_chapter_save';
  static const historyCommitMessageManualSceneSave =
      'history.commit_message.manual_scene_save';
  static const historyCommitMessageManualEpisodeOutlineSave =
      'history.commit_message.manual_episode_outline_save';
  static const historyCommitMessageManualCharacterSave =
      'history.commit_message.manual_character_save';
  static const historyCommitMessageManualEntrySave =
      'history.commit_message.manual_entry_save';
  static const historyCommitMessageManualForeshadowingSave =
      'history.commit_message.manual_foreshadowing_save';
  static const historyCommitMessageManualNovelDescriptionSave =
      'history.commit_message.manual_novel_description_save';
  static const historyCommitMessageRestoreToHistoricalVersion =
      'history.commit_message.restore_to_historical_version';
  static const historyCommitMessageRollbackChangeLines =
      'history.commit_message.rollback_change_lines';
  static const historyCommitMessageRollbackSelectedCommit =
      'history.commit_message.rollback_selected_commit';
  static const historyCommitMessageRollbackTurn =
      'history.commit_message.rollback_turn';
  static const historyEmpty = 'history.empty';
  static const historyFieldContent = 'history.field_content';
  static const historyFieldCurrentState = 'history.field_current_state';
  static const historyFieldDelta = 'history.field_delta';
  static const historyFieldGender = 'history.field_gender';
  static const historyFieldName = 'history.field_name';
  static const historyFieldPayoff = 'history.field_payoff';
  static const historyFieldParent = 'history.field_parent';
  static const historyFieldTension = 'history.field_tension';
  static const historyFieldResource = 'history.field_resource';
  static const historyFieldRole = 'history.field_role';
  static const historyFieldSetup = 'history.field_setup';
  static const historyFieldSkills = 'history.field_skills';
  static const historyFieldStatus = 'history.field_status';
  static const historyFieldSummary = 'history.field_summary';
  static const historyFieldSummaryOverflow = 'history.field_summary_overflow';
  static const historyFieldTitle = 'history.field_title';
  static const historyFieldIdentity = 'history.field_identity';
  static const historyFieldAge = 'history.field_age';
  static const historyFieldMotivation = 'history.field_motivation';
  static const historyFieldArc = 'history.field_arc';
  static const historyFieldCategory = 'history.field_category';
  static const historyFieldFirstAppearChapterId =
      'history.field_first_appear_chapter_id';
  static const historyFilterAll = 'history.filter_all';
  static const historyFilterSourceAi = 'history.filter_source_ai';
  static const historyFilterSourceManual = 'history.filter_source_manual';
  static const historyLoadingFailed = 'history.loading_failed';
  static const historyOpen = 'history.open';
  static const historyOpenForResource = 'history.open_for_resource';
  static const historyResourceHistoryEmpty = 'history.resource_history_empty';
  static const historyResourceHistoryTitle = 'history.resource_history_title';
  static const historyRevertAlreadyAtVersion =
      'history.revert_already_at_version';
  static const historyRevertConfirmAction = 'history.revert_confirm_action';
  static const historyRevertConfirmMessage = 'history.revert_confirm_message';
  static const historyRevertConfirmTitle = 'history.revert_confirm_title';
  static const historyRevertFailed = 'history.revert_failed';
  static const historyRevertSuccess = 'history.revert_success';
  static const historyRevertToVersion = 'history.revert_to_version';
  static const historyRollbackAlreadyApplied =
      'history.rollback_already_applied';
  static const historyRollbackCommitConfirmMessage =
      'history.rollback_commit_confirm_message';
  static const historyRollbackConfirmAction = 'history.rollback_confirm_action';
  static const historyRollbackConfirmMessage =
      'history.rollback_confirm_message';
  static const historyRollbackConfirmTitle = 'history.rollback_confirm_title';
  static const historyRollbackFailed = 'history.rollback_failed';
  static const historyRollbackSkipped = 'history.rollback_skipped';
  static const historyRestorePartial = 'history.restore_partial';
  static const historyRestoreSkipped = 'history.restore_skipped';
  static const historyRollbackSuccess = 'history.rollback_success';
  static const historyRollbackThisChange = 'history.rollback_this_change';
  static const historySelectACommit = 'history.select_a_commit';
  static const historySourceAi = 'history.source_ai';
  static const historySourceManual = 'history.source_manual';
  static const historyTitle = 'history.title';
  // ── home ────────────────────────────────────────
  static const homeAllWorks = 'home.all_works';
  static const homeCreateCardSubtitle = 'home.create_card_subtitle';
  static const homeCreateCardTitle = 'home.create_card_title';
  static const homeCreateScreenplayCardSubtitle =
      'home.create_screenplay_card_subtitle';
  static const homeCreateScreenplayCardTitle =
      'home.create_screenplay_card_title';
  static const homeDaysAgo = 'home.days_ago';
  static const homeEnterWork = 'home.enter_work';
  static const homeFeaturedContinueWriting = 'home.featured_continue_writing';
  static const homeFeaturedMore = 'home.featured_more';
  static const homeFilterDraft = 'home.filter_draft';
  static const homeGreetingAfternoon = 'home.greeting_afternoon';
  static const homeGreetingAfternoonShort = 'home.greeting_afternoon_short';
  static const homeGreetingEvening = 'home.greeting_evening';
  static const homeGreetingEveningShort = 'home.greeting_evening_short';
  static const homeGreetingMorning = 'home.greeting_morning';
  static const homeGreetingMorningShort = 'home.greeting_morning_short';
  static const homeGreetingNight = 'home.greeting_night';
  static const homeGreetingNightShort = 'home.greeting_night_short';
  static const homeGreetingPersonalized = 'home.greeting_personalized';
  static const homeGreetingPersonalizedSimple =
      'home.greeting_personalized_simple';
  static const homeRecentSessions = 'home.recent_sessions';
  static const homeRecentWork = 'home.recent_work';
  static const homeSectionAi = 'home.section_ai';
  static const homeSectionSettings = 'home.section_settings';
  static const homeSectionWorks = 'home.section_works';
  static const homeNavWorks = 'home.nav_works';
  static const homeResumeEyebrow = 'home.resume_eyebrow';
  static const homeResumeRecent = 'home.resume_recent';
  static const homeResumeLastWritten = 'home.resume_last_written';
  static const homeCreateWorkCardSubtitle = 'home.create_work_card_subtitle';
  static const homeSortRecent = 'home.sort_recent';
  static const homeSortCreated = 'home.sort_created';
  static const homeSortTitle = 'home.sort_title';
  static const homeSortWordCount = 'home.sort_word_count';
  static const homeSort = 'home.sort';
  static const homeFilterCategoryAll = 'home.filter_category_all';
  static const homeFilterUncategorized = 'home.filter_uncategorized';
  static const homeFilterAndSort = 'home.filter_and_sort';
  static const homeStatChapters = 'home.stat_chapters';
  static const homeStatCharacters = 'home.stat_characters';
  static const homeStatSettings = 'home.stat_settings';
  static const homeStatWords = 'home.stat_words';
  static const homeStatWordCount = 'home.stat_word_count';
  static const homeToday = 'home.today';
  static const homeTodayActiveWorks = 'home.today_active_works';
  static const homeTodayStatsTitle = 'home.today_stats_title';
  static const homeUpdateStatusFailed = 'home.update_status_failed';
  static const homeUpdateTimeSuffix = 'home.update_time_suffix';
  static const homeWritingAssistant = 'home.writing_assistant';
  static const homeYesterday = 'home.yesterday';
  // ── library ────────────────────────────────────────
  static const libraryActionAbandon = 'library.action_abandon';
  static const libraryActionAdapt = 'library.action_adapt';
  static const libraryActionArchive = 'library.action_archive';
  static const libraryActionFinish = 'library.action_finish';
  static const libraryActionRead = 'library.action_read';
  static const libraryActionResume = 'library.action_resume';
  static const libraryAdaptationTitle = 'library.adaptation_title';
  static const libraryAddToLibrary = 'library.add_to_library';
  static const libraryAddedToLibrary = 'library.added_to_library';
  static const libraryDraftShelfHint = 'library.draft_shelf_hint';
  static const libraryDrafts = 'library.drafts';
  static const libraryAddTag = 'library.add_tag';
  static const libraryCollectionInitializationFailed =
      'library.collection_initialization_failed';
  static const libraryCollectionUnavailable = 'library.collection_unavailable';
  static const libraryCollectionUnsupportedHint =
      'library.collection_unsupported_hint';
  static const libraryCollectionMore = 'library.collection_more';
  static const libraryCollectionMoveLeft = 'library.collection_move_left';
  static const libraryCollectionMoveRight = 'library.collection_move_right';
  static const libraryCollectionOrderFailed = 'library.collection_order_failed';
  static const libraryAll = 'library.all';
  static const libraryCollectionTitle = 'library.collection_title';
  static const libraryCollectionName = 'library.collection_name';
  static const libraryCollectionDeleteConfirm =
      'library.collection_delete_confirm';
  static const libraryCollectionAddTo = 'library.collection_add_to';
  static const libraryCollectionRemove = 'library.collection_remove';
  static const libraryCollectionAddWorks = 'library.collection_add_works';
  static const libraryCollectionSelected = 'library.collection_selected';
  static const libraryCollectionFailed = 'library.collection_failed';
  static const libraryCollectionLoadFailed = 'library.collection_load_failed';
  static const libraryCollectionMissing = 'library.collection_missing';
  static const libraryCollectionNameRequired =
      'library.collection_name_required';
  static const libraryCollectionAlreadyAdded =
      'library.collection_already_added';
  static const libraryCollectionNone = 'library.collection_none';
  static const libraryCategory = 'library.category';
  static const libraryCategoryHint = 'library.category_hint';
  static const libraryCategoryCustomHint = 'library.category_custom_hint';
  static const libraryCategoryBrowse = 'library.category_browse';
  static const libraryCategoryHide = 'library.category_hide';
  static const libraryCategoryQidian = 'library.category_qidian';
  static const libraryCategoryMale = 'library.category_male';
  static const libraryCategoryFemale = 'library.category_female';
  static const libraryContentKindNovel = 'library.content_kind_novel';
  static const libraryContentKindScreenplay = 'library.content_kind_screenplay';
  static const libraryContentKindAll = 'library.content_kind_all';
  static const libraryAuthorName = 'library.author_name';
  static const libraryCreateDemoNovel = 'library.create_demo_novel';
  static const libraryCreateDemoNovelDesc = 'library.create_demo_novel_desc';
  static const libraryCreateDemoNovelFailed =
      'library.create_demo_novel_failed';
  static const libraryCreateDemoNovelSuccess =
      'library.create_demo_novel_success';
  static const libraryCreateNovel = 'library.create_novel';
  static const libraryCreateNovelFailed = 'library.create_novel_failed';
  static const libraryCreateScreenplay = 'library.create_screenplay';
  static const libraryCreateWork = 'library.create_work';
  static const libraryCreateWorkFailed = 'library.create_work_failed';
  static const libraryMoreInfo = 'library.more_info';
  static const libraryMoreInfoHint = 'library.more_info_hint';
  static const libraryDuplicateName = 'library.duplicate_name';
  static const libraryCustomRules = 'library.custom_rules';
  static const libraryDatabaseLoadFailed = 'library.database_load_failed';
  static const libraryDeleteNovelConfirm = 'library.delete_novel_confirm';
  static const libraryDeleteNovelFailed = 'library.delete_novel_failed';
  static const libraryDeleteNovelSuccess = 'library.delete_novel_success';
  static const libraryDescription = 'library.description';
  static const libraryEditWorkInfo = 'library.edit_work_info';
  static const libraryExportAction = 'library.export_action';
  static const libraryExportAlignmentCenter = 'library.export_alignment_center';
  static const libraryExportAlignmentLeft = 'library.export_alignment_left';
  static const libraryExportAlignmentRight = 'library.export_alignment_right';
  static const libraryExportChapterNumberChinese =
      'library.export_chapter_number_chinese';
  static const libraryExportChapterNumberFormat =
      'library.export_chapter_number_format';
  static const libraryExportChapterNumberNumeric =
      'library.export_chapter_number_numeric';
  static const libraryExportChapterTitleAlignment =
      'library.export_chapter_title_alignment';
  static const libraryExportBodyFormat = 'library.export_body_format';
  static const libraryExportFailed = 'library.export_failed';
  static const libraryExportFolder = 'library.export_folder';
  static const libraryExportFolderPlaceholder =
      'library.export_folder_placeholder';
  static const libraryExportMobileFolderHint =
      'library.export_mobile_folder_hint';
  static const libraryExportNoContentDatabase =
      'library.export_no_content_database';
  static const libraryExportNovel = 'library.export_novel';
  static const libraryExportSelectFolder = 'library.export_select_folder';
  static const libraryExportScope = 'library.export_scope';
  static const libraryExportScopeChapterOutlines =
      'library.export_scope_chapter_outlines';
  static const libraryExportScopeChapterOutlinesHint =
      'library.export_scope_chapter_outlines_hint';
  static const libraryExportScopeBody = 'library.export_scope_body';
  static const libraryExportScopeBodyHint = 'library.export_scope_body_hint';
  static const libraryExportScreenplayBodyHint =
      'library.export_screenplay_body_hint';
  static const libraryExportScreenplayOutlinesHint =
      'library.export_screenplay_outlines_hint';
  static const libraryExportScopeCount = 'library.export_scope_count';
  static const libraryExportScopeDeselectAll =
      'library.export_scope_deselect_all';
  static const libraryExportScopeMaterials = 'library.export_scope_materials';
  static const libraryExportScopeMaterialsHint =
      'library.export_scope_materials_hint';
  static const libraryExportScopeOutlines = 'library.export_scope_outlines';
  static const libraryExportScopeOutlinesHint =
      'library.export_scope_outlines_hint';
  static const libraryExportScopeRequired = 'library.export_scope_required';
  static const libraryExportScopeSelectAll = 'library.export_scope_select_all';
  static const libraryExportScopeSettings = 'library.export_scope_settings';
  static const libraryExportScopeSettingsHint =
      'library.export_scope_settings_hint';
  static const libraryExportSuccess = 'library.export_success';
  static const libraryExporting = 'library.exporting';
  static const libraryMoreActions = 'library.more_actions';
  static const libraryMyNovels = 'library.my_novels';
  static const libraryNoDrafts = 'library.no_drafts';
  static const libraryNoDraftsHint = 'library.no_drafts_hint';
  static const libraryNoNovels = 'library.no_novels';
  static const libraryNoNovelsHint = 'library.no_novels_hint';
  static const libraryNoScreenplays = 'library.no_screenplays';
  static const libraryNoMatchingWorks = 'library.no_matching_works';
  static const libraryClearFilters = 'library.clear_filters';
  static const libraryNovelName = 'library.novel_name';
  static const libraryNovelType = 'library.novel_type';
  static const libraryNovelTypeAdaptation = 'library.novel_type_adaptation';
  static const libraryNovelTypeDerivative = 'library.novel_type_derivative';
  static const libraryNovelTypeFanfic = 'library.novel_type_fanfic';
  static const libraryNovelTypeMaterial = 'library.novel_type_material';
  static const libraryNovelTypeOriginal = 'library.novel_type_original';
  static const libraryNovelTypeSequel = 'library.novel_type_sequel';
  static const libraryPlannedEpisodeCount = 'library.planned_episode_count';
  static const libraryPlannedEpisodeCountHint =
      'library.planned_episode_count_hint';
  static const libraryPlannedEpisodeCountInvalid =
      'library.planned_episode_count_invalid';
  static const libraryImportingTxt = 'library.importing_txt';
  static const libraryImportTagsHint = 'library.import_tags_hint';
  static const libraryImportTxt = 'library.import_txt';
  static const libraryImportTxtEmpty = 'library.import_txt_empty';
  static const libraryImportTxtFailed = 'library.import_txt_failed';
  static const libraryImportTxtSuccess = 'library.import_txt_success';
  static const libraryImportTxtSummary = 'library.import_txt_summary';
  static const libraryQuickStartIdeaHint = 'library.quick_start_idea_hint';
  static const libraryQuickStartIdeaHelp = 'library.quick_start_idea_help';
  static const libraryQuickStartConfirm = 'library.quick_start_confirm';
  static const libraryQuickStart = 'library.quick_start';
  static const libraryQuickStartChatHint = 'library.quick_start_chat_hint';
  static const libraryAdaptBannerTitle = 'library.adapt_banner_title';
  static const libraryAdaptBannerHint = 'library.adapt_banner_hint';
  static const libraryQuickStartHint = 'library.quick_start_hint';
  static const libraryScreenplayWorkspacePreparing =
      'library.screenplay_workspace_preparing';
  static const librarySearchPlaceholder = 'library.search_placeholder';
  static const librarySourceNovel = 'library.source_novel';
  static const librarySourceNovelAdaptation = 'library.source_novel_adaptation';
  static const librarySourceNovelDerivative = 'library.source_novel_derivative';
  static const librarySourceNovelFanfic = 'library.source_novel_fanfic';
  static const librarySourceNovelNone = 'library.source_novel_none';
  static const librarySourceNovelNoneAdaptation =
      'library.source_novel_none_adaptation';
  static const librarySourceNovelNoneDerivative =
      'library.source_novel_none_derivative';
  static const librarySourceNovelNoneFanfic =
      'library.source_novel_none_fanfic';
  static const librarySourceNovelNoneSequel =
      'library.source_novel_none_sequel';
  static const librarySourceNovelSequel = 'library.source_novel_sequel';
  static const libraryWorkspaceLoadFailed = 'library.workspace_load_failed';
  static const libraryWorkName = 'library.work_name';
  static const librarySelectCover = 'library.select_cover';
  static const libraryStartImport = 'library.start_import';
  static const librarySettings = 'library.settings';
  static const libraryStatusAbandoned = 'library.status_abandoned';
  static const libraryStatusArchived = 'library.status_archived';
  static const libraryStatusFinished = 'library.status_finished';
  static const libraryStatusInProgress = 'library.status_in_progress';
  static const libraryTagHint = 'library.tag_hint';
  static const libraryTags = 'library.tags';
  static const libraryTitle = 'library.title';
  static const libraryUntitledNovel = 'library.untitled_novel';
  // ── location ────────────────────────────────────────
  static const locationTypeBuilding = 'location.type.building';
  static const locationTypeCity = 'location.type.city';
  static const locationTypeContinent = 'location.type.continent';
  static const locationTypeCountry = 'location.type.country';
  static const locationTypeCustom = 'location.type.custom';
  static const locationTypeDistrict = 'location.type.district';
  static const locationTypeForest = 'location.type.forest';
  static const locationTypeGeneric = 'location.type.generic';
  static const locationTypeIsland = 'location.type.island';
  static const locationTypeLake = 'location.type.lake';
  static const locationTypeLandmark = 'location.type.landmark';
  static const locationTypeMountain = 'location.type.mountain';
  static const locationTypeNatural = 'location.type.natural';
  static const locationTypePlain = 'location.type.plain';
  static const locationTypeRegion = 'location.type.region';
  static const locationTypeRiver = 'location.type.river';
  static const locationTypeRoom = 'location.type.room';
  static const locationTypeSea = 'location.type.sea';
  static const locationTypeVillage = 'location.type.village';
  static const locationTypeWorld = 'location.type.world';
  // ── map ────────────────────────────────────────
  static const mapTypeBuilding = 'map.type.building';
  static const mapTypeCity = 'map.type.city';
  static const mapTypeDungeon = 'map.type.dungeon';
  static const mapTypeRegion = 'map.type.region';
  static const mapTypeWorld = 'map.type.world';
  // ── map_editor ────────────────────────────────────────
  static const mapEditorAddCity = 'map_editor.add_city';
  static const mapEditorAddConnection = 'map_editor.add_connection';
  static const mapEditorAddConnectionTitle = 'map_editor.add_connection_title';
  static const mapEditorAddLandmarks = 'map_editor.add_landmarks';
  static const mapEditorAddLocation = 'map_editor.add_location';
  static const mapEditorAddLocationTitle = 'map_editor.add_location_title';
  static const mapEditorAiCopilot = 'map_editor.ai_copilot';
  static const mapEditorAiCopilotHint = 'map_editor.ai_copilot_hint';
  static const mapEditorAiDraftPrompt = 'map_editor.ai_draft_prompt';
  static const mapEditorAiModelHeader = 'map_editor.ai_model_header';
  static const mapEditorApplyGeometry = 'map_editor.apply_geometry';
  static const mapEditorArea = 'map_editor.area';
  static const mapEditorAssetBackground = 'map_editor.asset_background';
  static const mapEditorAssetIcons = 'map_editor.asset_icons';
  static const mapEditorAssetStyles = 'map_editor.asset_styles';
  static const mapEditorAssets = 'map_editor.assets';
  static const mapEditorCancelDrawing = 'map_editor.cancel_drawing';
  static const mapEditorStudioTitle = 'map_editor.studio_title';
  static const mapEditorStudioSubtitle = 'map_editor.studio_subtitle';
  static const mapEditorStudioTabGenerate = 'map_editor.studio_tab_generate';
  static const mapEditorStudioTabLocation = 'map_editor.studio_tab_location';
  static const mapEditorStudioTabHistory = 'map_editor.studio_tab_history';
  static const mapEditorStudioHistoryEmpty = 'map_editor.studio_history_empty';
  static const mapEditorStudioHistoryLoadFailed =
      'map_editor.studio_history_load_failed';
  static const mapEditorStudioHistoryRecognizeOnApply =
      'map_editor.studio_history_recognize_on_apply';
  static const mapEditorStudioAssetSaveFailed =
      'map_editor.studio_asset_save_failed';
  static const mapEditorStudioHistoryReadFailed =
      'map_editor.studio_history_read_failed';
  static const mapEditorStudioPainting = 'map_editor.studio_painting';
  static const mapEditorStudioSources = 'map_editor.studio_sources';
  static const mapEditorStudioSourceLocations =
      'map_editor.studio_source_locations';
  static const mapEditorStudioSourceLocationsNote =
      'map_editor.studio_source_locations_note';
  static const mapEditorStudioSourceCurrentImage =
      'map_editor.studio_source_current_image';
  static const mapEditorStudioSourceCurrentImageNote =
      'map_editor.studio_source_current_image_note';
  static const mapEditorStudioSourceParentImage =
      'map_editor.studio_source_parent_image';
  static const mapEditorStudioSourceParentImageNote =
      'map_editor.studio_source_parent_image_note';
  static const mapEditorStudioStyle = 'map_editor.studio_style';
  static const mapEditorStudioStyleParchment =
      'map_editor.studio_style_parchment';
  static const mapEditorStudioStyleInkmap = 'map_editor.studio_style_inkmap';
  static const mapEditorStudioStyleEngraving =
      'map_editor.studio_style_engraving';
  static const mapEditorStudioStyleRealistic =
      'map_editor.studio_style_realistic';
  static const mapEditorStudioStyleWoodcut = 'map_editor.studio_style_woodcut';
  static const mapEditorStudioStyleWatercolor =
      'map_editor.studio_style_watercolor';
  static const mapEditorStudioStyleAtlas = 'map_editor.studio_style_atlas';
  static const mapEditorStudioStyleCustom = 'map_editor.studio_style_custom';
  static const mapEditorStudioStyleCustomHint =
      'map_editor.studio_style_custom_hint';
  static const mapEditorStudioStyleCustomRequired =
      'map_editor.studio_style_custom_required';
  static const mapEditorStudioSize = 'map_editor.studio_size';
  static const mapEditorStudioResolution = 'map_editor.studio_resolution';
  static const mapEditorStudioQuality = 'map_editor.studio_quality';
  static const mapEditorStudioPrompt = 'map_editor.studio_prompt';
  static const mapEditorStudioPromptReset = 'map_editor.studio_prompt_reset';
  static const mapEditorStudioPromptHint = 'map_editor.studio_prompt_hint';
  static const mapEditorStudioNeedsLocations =
      'map_editor.studio_needs_locations';
  static const mapEditorStudioGenerate = 'map_editor.studio_generate';
  static const mapEditorStudioOpenCartographer =
      'map_editor.studio_open_cartographer';
  static const mapEditorGenerationSwitchBlocked =
      'map_editor.generation_switch_blocked';
  static const mapEditorStudioCostNote = 'map_editor.studio_cost_note';
  static const mapEditorStudioExport = 'map_editor.studio_export';
  static const mapEditorStudioExported = 'map_editor.studio_exported';
  static const mapEditorStudioVersionLabel = 'map_editor.studio_version_label';
  static const mapEditorStudioNotDrawn = 'map_editor.studio_not_drawn';
  static const mapEditorStudioEmptyTitle = 'map_editor.studio_empty_title';
  static const mapEditorStudioStageRead = 'map_editor.studio_stage_read';
  static const mapEditorStudioStageImage = 'map_editor.studio_stage_image';
  static const mapEditorStudioStageLocate = 'map_editor.studio_stage_locate';
  static const mapEditorStudioStageVerify = 'map_editor.studio_stage_verify';
  static const mapEditorStudioReviewTitle = 'map_editor.studio_review_title';
  static const mapEditorStudioReviewNote = 'map_editor.studio_review_note';
  static const mapEditorStudioAdopt = 'map_editor.studio_adopt';
  static const mapEditorStudioRegenerate = 'map_editor.studio_regenerate';
  static const mapEditorStudioStatUnmatched =
      'map_editor.studio_stat_unmatched';
  static const mapEditorStudioFieldName = 'map_editor.studio_field_name';
  static const mapEditorStudioFieldType = 'map_editor.studio_field_type';
  static const mapEditorStudioFieldDescription =
      'map_editor.studio_field_description';
  static const mapEditorStudioFieldPhotos = 'map_editor.studio_field_photos';
  static const mapEditorStudioRailNoMaps = 'map_editor.studio_rail_no_maps';
  static const mapEditorStudioRailNoLocations =
      'map_editor.studio_rail_no_locations';
  static const mapEditorStudioRailPlaces = 'map_editor.studio_rail_places';
  static const mapEditorStudioPickPlace = 'map_editor.studio_pick_place';
  static const mapEditorStudioSubmaps = 'map_editor.studio_submaps';
  static const mapEditorStudioOpenMap = 'map_editor.studio_open_map';
  static const mapEditorStudioNewMap = 'map_editor.studio_new_map';
  static const mapEditorStudioCreateMapFor = 'map_editor.studio_create_map_for';
  static const mapEditorStudioMapLocation = 'map_editor.studio_map_location';
  static const mapEditorStudioNoLocation = 'map_editor.studio_no_location';
  static const mapEditorTypeWorld = 'map_editor.type_world';
  static const mapEditorTypeContinent = 'map_editor.type_continent';
  static const mapEditorTypeCountry = 'map_editor.type_country';
  static const mapEditorTypeRegion = 'map_editor.type_region';
  static const mapEditorTypeMountain = 'map_editor.type_mountain';
  static const mapEditorTypePlain = 'map_editor.type_plain';
  static const mapEditorTypeForest = 'map_editor.type_forest';
  static const mapEditorTypeRiver = 'map_editor.type_river';
  static const mapEditorTypeLake = 'map_editor.type_lake';
  static const mapEditorTypeSea = 'map_editor.type_sea';
  static const mapEditorTypeIsland = 'map_editor.type_island';
  static const mapEditorTypeCity = 'map_editor.type_city';
  static const mapEditorTypeVillage = 'map_editor.type_village';
  static const mapEditorTypeBuilding = 'map_editor.type_building';
  static const mapEditorTypeLandmark = 'map_editor.type_landmark';
  static const mapEditorTypeGeneric = 'map_editor.type_generic';
  static const mapEditorCanvas = 'map_editor.canvas';
  static const mapEditorChildMap = 'map_editor.child_map';
  static const mapEditorChildLocations = 'map_editor.child_locations';
  static const mapEditorCities = 'map_editor.cities';
  static const mapEditorConnectionCount = 'map_editor.connection_count';
  static const mapEditorContinents = 'map_editor.continents';
  static const mapEditorConvertToPolygon = 'map_editor.convert_to_polygon';
  static const mapEditorCoordX = 'map_editor.coord_x';
  static const mapEditorCoordY = 'map_editor.coord_y';
  static const mapEditorCreateLocation = 'map_editor.create_location';
  static const mapEditorCreateLocationTitle =
      'map_editor.create_location_title';
  static const mapEditorCreateWorldTitle = 'map_editor.create_world_title';
  static const mapEditorCurrentVersion = 'map_editor.current_version';
  static const mapEditorDeleteLocationConfirm =
      'map_editor.delete_location_confirm';
  static const mapEditorDeleteLocationTitle =
      'map_editor.delete_location_title';
  static const mapEditorDraftPromptPlaceholder =
      'map_editor.draft_prompt_placeholder';
  static const mapEditorDrawPolygon = 'map_editor.draw_polygon';
  static const mapEditorDrawRegion = 'map_editor.draw_region';
  static const mapEditorExpandRegion = 'map_editor.expand_region';
  static const mapEditorExportJson = 'map_editor.export_json';
  static const mapEditorFactionStats = 'map_editor.faction_stats';
  static const mapEditorFinishPolygon = 'map_editor.finish_polygon';
  static const mapEditorGenerateRegionLore = 'map_editor.generate_region_lore';
  static const mapEditorGeometry = 'map_editor.geometry';
  static const mapEditorImportJson = 'map_editor.import_json';
  static const mapEditorInsertVertex = 'map_editor.insert_vertex';
  static const mapEditorInspector = 'map_editor.inspector';
  static const mapEditorJsonImported = 'map_editor.json_imported';
  static const mapEditorJsonInterface = 'map_editor.json_interface';
  static const mapEditorJsonInvalid = 'map_editor.json_invalid';
  static const mapEditorKeyLocations = 'map_editor.key_locations';
  static const mapEditorKingdoms = 'map_editor.kingdoms';
  static const mapEditorLandmark = 'map_editor.landmark';
  static const mapEditorLayerBorders = 'map_editor.layer_borders';
  static const mapEditorLayerCities = 'map_editor.layer_cities';
  static const mapEditorLayerLandmarks = 'map_editor.layer_landmarks';
  static const mapEditorLayerLock = 'map_editor.layer_lock';
  static const mapEditorLayerRoutes = 'map_editor.layer_routes';
  static const mapEditorLayerVisibility = 'map_editor.layer_visibility';
  static const mapEditorLayers = 'map_editor.layers';
  static const mapEditorLayersTab = 'map_editor.layers_tab';
  static const mapEditorLegend = 'map_editor.legend';
  static const mapEditorLibrary = 'map_editor.library';
  static const mapEditorLibraryHint = 'map_editor.library_hint';
  static const mapEditorLoadDemoData = 'map_editor.load_demo_data';
  static const mapEditorLoadFailed = 'map_editor.load_failed';
  static const mapEditorLocationCount = 'map_editor.location_count';
  static const mapEditorLocationCreated = 'map_editor.location_created';
  static const mapEditorLocationDescriptionHint =
      'map_editor.location_description_hint';
  static const mapEditorLocationNameDuplicate =
      'map_editor.location_name_duplicate';
  static const mapEditorLocationNameHint = 'map_editor.location_name_hint';
  static const mapEditorLocationNameRequired =
      'map_editor.location_name_required';
  static const mapEditorLocationUpdated = 'map_editor.location_updated';
  static const mapEditorMapSettings = 'map_editor.map_settings';
  static const mapEditorMapSummary = 'map_editor.map_summary';
  static const mapEditorMapTab = 'map_editor.map_tab';
  static const mapEditorMapVersions = 'map_editor.map_versions';
  static const mapEditorMeasure = 'map_editor.measure';
  static const mapEditorNeedTwoLocations = 'map_editor.need_two_locations';
  static const mapEditorNoChildMap = 'map_editor.no_child_map';
  static const mapEditorNoDescription = 'map_editor.no_description';
  static const mapEditorNoLocationsAvailable =
      'map_editor.no_locations_available';
  static const mapEditorNoParentLocation = 'map_editor.no_parent_location';
  static const mapEditorNoSelection = 'map_editor.no_selection';
  static const mapEditorOpenChildMap = 'map_editor.open_child_map';
  static const mapEditorOthersGroup = 'map_editor.others_group';
  static const mapEditorPan = 'map_editor.pan';
  static const mapEditorParentLocation = 'map_editor.parent_location';
  static const mapEditorPolygonDrawHint = 'map_editor.polygon_draw_hint';
  static const mapEditorPolygonNeedMorePoints =
      'map_editor.polygon_need_more_points';
  static const mapEditorPolygonReadOnly = 'map_editor.polygon_read_only';
  static const mapEditorPolygonVertices = 'map_editor.polygon_vertices';
  static const mapEditorPosition = 'map_editor.position';
  static const mapEditorQuickActions = 'map_editor.quick_actions';
  static const mapEditorRedo = 'map_editor.redo';
  static const mapEditorResetView = 'map_editor.reset_view';
  static const mapEditorRoute = 'map_editor.route';
  static const mapEditorRoutes = 'map_editor.routes';
  static const mapEditorSearchPlaceholder = 'map_editor.search_placeholder';
  static const mapEditorSelect = 'map_editor.select';
  static const mapEditorSelectLocation = 'map_editor.select_location';
  static const mapEditorSettings = 'map_editor.settings';
  static const mapEditorSourceLocation = 'map_editor.source_location';
  static const mapEditorSuggestCities = 'map_editor.suggest_cities';
  static const mapEditorTags = 'map_editor.tags';
  static const mapEditorTagsHint = 'map_editor.tags_hint';
  static const mapEditorTargetLocation = 'map_editor.target_location';
  static const mapEditorTerritories = 'map_editor.territories';
  static const mapEditorTotal = 'map_editor.total';
  static const mapEditorUndo = 'map_editor.undo';
  static const mapEditorViewAllLocations = 'map_editor.view_all_locations';
  static const mapEditorViewAllVersions = 'map_editor.view_all_versions';
  static const mapEditorWorkspace = 'map_editor.workspace';
  static const mapEditorWorkspaceHint = 'map_editor.workspace_hint';
  static const mapEditorWorldDescriptionHint =
      'map_editor.world_description_hint';
  static const mapEditorWorldMap = 'map_editor.world_map';
  static const mapEditorWorldName = 'map_editor.world_name';
  static const mapEditorWorldNameHint = 'map_editor.world_name_hint';
  static const mapEditorZoomIn = 'map_editor.zoom_in';
  static const mapEditorZoomOut = 'map_editor.zoom_out';
  // ── memory ────────────────────────────────────────
  static const memoryAutoExtract = 'memory.auto_extract';
  static const memoryAutoExtractDescription = 'memory.auto_extract_description';
  static const memoryCategory = 'memory.category';
  static const memoryCategoryCharacter = 'memory.category_character';
  static const memoryCategoryDecision = 'memory.category_decision';
  static const memoryCategoryFact = 'memory.category_fact';
  static const memoryCategoryPreference = 'memory.category_preference';
  static const memoryCategoryStyle = 'memory.category_style';
  static const memoryCategoryWorldview = 'memory.category_worldview';
  static const memoryContent = 'memory.content';
  static const memoryContentHint = 'memory.content_hint';
  static const memoryContentRequired = 'memory.content_required';
  static const memoryDeleteConfirm = 'memory.delete_confirm';
  static const memoryDescription = 'memory.description';
  static const memoryDisabled = 'memory.disabled';
  static const memoryDreamNow = 'memory.dream_now';
  static const memoryEmpty = 'memory.empty';
  static const memoryEnabled = 'memory.enabled';
  static const memoryExtractNow = 'memory.extract_now';
  static const memoryExtracting = 'memory.extracting';
  static const memoryExtractionComplete = 'memory.extraction_complete';
  static const memoryExtractionInterval = 'memory.extraction_interval';
  static const memoryExtractionIntervalHint = 'memory.extraction_interval_hint';
  static const memoryGlobal = 'memory.global';
  static const memoryNovel = 'memory.novel';
  static const memoryPriority = 'memory.priority';
  static const memoryPriorityContext = 'memory.priority_context';
  static const memoryPriorityCore = 'memory.priority_core';
  static const memorySourceAuto = 'memory.source_auto';
  static const memoryTitle = 'memory.title';
  // ── mobile ────────────────────────────────────────
  static const mobileAssistantDesc = 'mobile.assistant_desc';
  static const mobileAssistantTitle = 'mobile.assistant_title';
  static const mobileChatHistorySubtitle = 'mobile.chat_history_subtitle';
  static const mobileChatEmptyTitle = 'mobile.chat_empty_title';
  static const mobileChatEmptyDesc = 'mobile.chat_empty_desc';
  static const mobileChatLoadFailed = 'mobile.chat_load_failed';
  static const mobileChatUnknownNovel = 'mobile.chat_unknown_novel';
  static const mobileChatStartFailed = 'mobile.chat_start_failed';
  static const mobileChatSend = 'mobile.chat_send';
  static const mobileChatStop = 'mobile.chat_stop';
  static const mobileChatEmptyConversation = 'mobile.chat_empty_conversation';
  static const mobileChatModelTitle = 'mobile.chat_model_title';
  static const mobileChatModelSubtitle = 'mobile.chat_model_subtitle';
  static const mobileChatNoModels = 'mobile.chat_no_models';
  static const mobileChatModelDefault = 'mobile.chat_model_default';
  static const mobileChatQueuedPrefix = 'mobile.chat_queued_prefix';
  static const mobileChatReferenceTitle = 'mobile.chat_reference_title';
  static const mobileChatReferenceEmpty = 'mobile.chat_reference_empty';
  static const mobileChatReferenceSearch = 'mobile.chat_reference_search';
  static const mobileEditorAiAssistant = 'mobile.editor_ai_assistant';
  static const mobileEditorAddSubLocation = 'mobile.editor_add_sub_location';
  static const mobileEditorAutosaveAt = 'mobile.editor_autosave_at';
  static const mobileEditorBodyHint = 'mobile.editor_body_hint';
  static const mobileEditorChapterTitleHint =
      'mobile.editor_chapter_title_hint';
  static const mobileEditorComingSoon = 'mobile.editor_coming_soon';
  static const mobileEditorCurrent = 'mobile.editor_current';
  static const mobileEditorDeleteEntryMessage =
      'mobile.editor_delete_entry_message';
  static const mobileEditorDeleteFolderMessage =
      'mobile.editor_delete_folder_message';
  static const mobileEditorDeleteLocationMessage =
      'mobile.editor_delete_location_message';
  static const mobileEditorEntryNoContent = 'mobile.editor_entry_no_content';
  static const mobileEditorDraftNotStarted = 'mobile.editor_draft_not_started';
  static const mobileChapterNotStarted = 'mobile.chapter_not_started';
  static const mobileEditorNewLocation = 'mobile.editor_new_location';
  static const mobileEditorNewWorld = 'mobile.editor_new_world';
  static const mobileEditorSaving = 'mobile.editor_saving';
  static const mobileEditorSubLocationCount =
      'mobile.editor_sub_location_count';
  static const mobileEditorSubLocations = 'mobile.editor_sub_locations';
  static const mobileEditorCharactersTitle = 'mobile.editor_characters_title';
  static const mobileEditorMentionedEntities =
      'mobile.editor_mentioned_entities';
  static const mobileEditorNoCharacters = 'mobile.editor_no_characters';
  static const mobileEditorSelectChapter = 'mobile.editor_select_chapter';
  static const mobileEditorTocTitle = 'mobile.editor_toc_title';
  static const mobileEditorWordCount = 'mobile.editor_word_count';
  static const mobileAssistantModesSection = 'mobile.assistant_modes_section';
  static const mobileAssistantManageSection = 'mobile.assistant_manage_section';
  static const mobileAssistantRecentSection = 'mobile.assistant_recent_section';
  static const mobileAssistantPrimarySubtitle =
      'mobile.assistant_primary_subtitle';
  static const mobileAssistantPrimarySubtitleNew =
      'mobile.assistant_primary_subtitle_new';
  static const mobileAssistantChatButton = 'mobile.assistant_chat_button';
  static const mobileAssistantPickNovelTitle =
      'mobile.assistant_pick_novel_title';
  static const mobileAssistantNoNovelHint = 'mobile.assistant_no_novel_hint';
  static const mobileAssistantCount = 'mobile.assistant_count';
  static const mobileAssistantPromptsTitle = 'mobile.assistant_prompts_title';
  static const mobileAssistantEnableHint = 'mobile.assistant_enable_hint';
  static const mobileTabAssistant = 'mobile.tab_assistant';
  static const mobileTabLibrary = 'mobile.tab_library';
  static const mobileTabSettings = 'mobile.tab_settings';
  // ── monologue ────────────────────────────────────────
  static const monologueContinue = 'monologue.continue';
  static const monologueDefaultTitle = 'monologue.default_title';
  static const monologueGenerating = 'monologue.generating';
  static const monologueInnerThoughts = 'monologue.inner_thoughts';
  static const monologueInnerThoughtsLabel = 'monologue.inner_thoughts_label';
  static const monologueNew = 'monologue.new';
  static const monologueNoCharacters = 'monologue.no_characters';
  static const monologuePlannedActions = 'monologue.planned_actions';
  static const monologuePlannedActionsLabel = 'monologue.planned_actions_label';
  static const monologueSelectCharacter = 'monologue.select_character';
  static const monologueSelectedChip = 'monologue.selected_chip';
  static const monologueSessionTitleFmt = 'monologue.session_title_fmt';
  static const monologueStart = 'monologue.start';
  static const monologueThinkingFmt = 'monologue.thinking_fmt';
  static const monologueTopic = 'monologue.topic';
  static const monologueTopicHint = 'monologue.topic_hint';
  // ── name_assistant ────────────────────────────────────────
  static const nameAssistantAI = 'name_assistant.ai';
  static const nameAssistantAIError = 'name_assistant.ai_error';
  static const nameAssistantGenerating = 'name_assistant.generating';
  static const nameAssistantRandom = 'name_assistant.random';
  static const nameAssistantTitle = 'name_assistant.title';
  static const nameAssistantUseName = 'name_assistant.use_name';
  // ── onboarding ────────────────────────────────────────
  static const onboardingAiProviderDescription =
      'onboarding.ai_provider_description';
  static const onboardingAiProviderTitle = 'onboarding.ai_provider_title';
  static const onboardingProviderStatusReady =
      'onboarding.provider_status_ready';
  static const onboardingProviderStatusNeedsSetup =
      'onboarding.provider_status_needs_setup';
  static const onboardingProviderStatusDisabled =
      'onboarding.provider_status_disabled';
  static const onboardingAvatarLabel = 'onboarding.avatar_label';
  static const onboardingAvatarSelect = 'onboarding.avatar_select';
  static const onboardingAvatarUpload = 'onboarding.avatar_upload';
  static const onboardingAvatarFormatHint = 'onboarding.avatar_format_hint';
  static const onboardingProfileCardTitle = 'onboarding.profile_card_title';
  static const onboardingProfileCardSubtitle =
      'onboarding.profile_card_subtitle';
  static const onboardingBrandWelcome = 'onboarding.brand_welcome';
  static const onboardingBrandTagline = 'onboarding.brand_tagline';
  static const onboardingFeatureFocusTitle = 'onboarding.feature_focus_title';
  static const onboardingFeatureFocusSubtitle =
      'onboarding.feature_focus_subtitle';
  static const onboardingFeatureInspirationTitle =
      'onboarding.feature_inspiration_title';
  static const onboardingFeatureInspirationSubtitle =
      'onboarding.feature_inspiration_subtitle';
  static const onboardingFeatureKnowledgeTitle =
      'onboarding.feature_knowledge_title';
  static const onboardingFeatureKnowledgeSubtitle =
      'onboarding.feature_knowledge_subtitle';
  static const onboardingReplayIntro = 'onboarding.replay_intro';
  static const onboardingBack = 'onboarding.back';
  static const onboardingCreatingDemo = 'onboarding.creating_demo';
  static const onboardingGetStarted = 'onboarding.get_started';
  static const onboardingLanguageDescription =
      'onboarding.language_description';
  static const onboardingLanguageTitle = 'onboarding.language_title';
  static const onboardingNext = 'onboarding.next';
  static const onboardingSkip = 'onboarding.skip';
  static const onboardingStep = 'onboarding.step';
  static const onboardingTitle = 'onboarding.title';
  static const onboardingUserProfileDescription =
      'onboarding.user_profile_description';
  static const onboardingUserProfileTitle = 'onboarding.user_profile_title';
  static const onboardingUsernameHint = 'onboarding.username_hint';
  static const onboardingUsernameLabel = 'onboarding.username_label';
  static const onboardingWelcome = 'onboarding.welcome';
  static const onboardingThemeTitle = 'onboarding.theme_title';
  static const onboardingThemeDescription = 'onboarding.theme_description';
  static const onboardingModelDefaultsTitle = 'onboarding.model_defaults_title';
  static const onboardingModelDefaultsDescription =
      'onboarding.model_defaults_description';
  // ── reading ────────────────────────────────────────
  static const readingTitle = 'reading.title';
  static const readingLibraryTitle = 'reading.library_title';
  static const readingLibraryDescription = 'reading.library_description';
  static const readingLibraryEmpty = 'reading.library_empty';
  static const readingLibraryEmptyDescription =
      'reading.library_empty_description';
  static const readingOpen = 'reading.open';
  static const readingContinue = 'reading.continue';
  static const readingStartFromBeginning = 'reading.start_from_beginning';
  static const readingResumeFrom = 'reading.resume_from';
  static const readingReaderTitle = 'reading.reader_title';
  static const readingTableOfContents = 'reading.table_of_contents';
  static const readingPinWindow = 'reading.pin_window';
  static const readingUnpinWindow = 'reading.unpin_window';
  static const readingPreviousChapter = 'reading.previous_chapter';
  static const readingNextChapter = 'reading.next_chapter';
  static const readingNoPreviousChapter = 'reading.no_previous_chapter';
  static const readingNoNextChapter = 'reading.no_next_chapter';
  static const readingChapterProgress = 'reading.chapter_progress';
  static const readingOverallProgress = 'reading.overall_progress';
  static const readingProgressLabel = 'reading.progress_label';
  static const readingChapterCount = 'reading.chapter_count';
  static const readingWordCount = 'reading.word_count';
  static const readingReadingTime = 'reading.reading_time';
  static const readingSettingsTitle = 'reading.settings_title';
  static const readingExit = 'reading.exit';
  static const readingBrightness = 'reading.brightness';
  static const readingNightMode = 'reading.night_mode';
  static const readingExitNightMode = 'reading.exit_night_mode';
  static const readingNoContent = 'reading.no_content';
  static const readingNoChapters = 'reading.no_chapters';
  static const readingNoChaptersDescription = 'reading.no_chapters_description';
  static const readingFontPreview = 'reading.font_preview';
  static const readingMinuteShort = 'reading.minute_short';
  static const readingChapterShort = 'reading.chapter_short';
  // ── relation ────────────────────────────────────────
  static const relationCharacterAlterEgo = 'relation.character.alter_ego';
  static const relationCharacterColleague = 'relation.character.colleague';
  static const relationCharacterEnemy = 'relation.character.enemy';
  static const relationCharacterFamily = 'relation.character.family';
  static const relationCharacterFriend = 'relation.character.friend';
  static const relationCharacterGrandparent = 'relation.character.grandparent';
  static const relationCharacterLover = 'relation.character.lover';
  static const relationCharacterMasterDisciple =
      'relation.character.master_disciple';
  static const relationCharacterParent = 'relation.character.parent';
  static const relationCharacterSibling = 'relation.character.sibling';
  static const relationCharacterSubordinate = 'relation.character.subordinate';
  static const relationFactionAlly = 'relation.faction.ally';
  static const relationFactionEnemy = 'relation.faction.enemy';
  static const relationFactionFounder = 'relation.faction.founder';
  static const relationFactionLeader = 'relation.faction.leader';
  static const relationFactionMember = 'relation.faction.member';
  static const relationFactionSubordinate = 'relation.faction.subordinate';
  static const relationCreatureEvolvesTo = 'relation.creature.evolves_to';
  static const relationCreaturePredator = 'relation.creature.predator';
  static const relationCreaturePrey = 'relation.creature.prey';
  static const relationEvolvesTo = 'relation.evolves_to';
  static const relationItemCreator = 'relation.item.creator';
  static const relationItemEvolvesTo = 'relation.item.evolves_to';
  static const relationItemFormerOwner = 'relation.item.former_owner';
  static const relationItemOwner = 'relation.item.owner';
  static const relationItemPartOf = 'relation.item.part_of';
  static const relationItemUser = 'relation.item.user';
  static const relationSkillBranch = 'relation.skill.branch';
  static const relationSkillCreator = 'relation.skill.creator';
  static const relationSkillEvolvesTo = 'relation.skill.evolves_to';
  static const relationSkillLearned = 'relation.skill.learned';
  static const relationSkillMastered = 'relation.skill.mastered';
  static const relationSkillMastering = 'relation.skill.mastering';
  static const relationSkillPrerequisite = 'relation.skill.prerequisite';
  static const relationActive = 'relation.active';
  static const relationEnded = 'relation.ended';
  static const relationShowEnded = 'relation.show_ended';
  static const relationRecordChange = 'relation.record_change';
  static const relationChangeHint = 'relation.change_hint';
  static const relationCorrectHint = 'relation.correct_hint';
  static const relationEndHint = 'relation.end_hint';
  static const relationRestoreHint = 'relation.restore_hint';
  static const relationFormProof = 'relation.form_proof';
  static const relationReasonHint = 'relation.reason_hint';
  static const relationProofHint = 'relation.proof_hint';
  static const relationCorrectRecord = 'relation.correct_record';
  static const relationEndRelation = 'relation.end_relation';
  static const relationRestoreRelation = 'relation.restore_relation';
  static const relationHistoryCount = 'relation.history_count';
  static const relationNoHistory = 'relation.no_history';
  static const relationBaseline = 'relation.baseline';
  static const relationBaselineTime = 'relation.baseline_time';
  static const relationRecordedAt = 'relation.recorded_at';
  static const relationRemoveChange = 'relation.remove_change';
  static const relationRemoveLatestConfirm = 'relation.remove_latest_confirm';
  static const relationRemoveEarlierConfirm = 'relation.remove_earlier_confirm';
  static const relationDeleteRelation = 'relation.delete_relation';
  static const relationDeleteConfirm = 'relation.delete_confirm';
  static const relationEvidenceDeleted = 'relation.evidence_deleted';
  static const relationSettingEvidence = 'relation.setting_evidence';
  static const relationProof = 'relation.proof';
  static const relationReason = 'relation.reason';
  static const relationEvidence = 'relation.evidence';
  static const relationEvidenceChapter = 'relation.evidence_chapter';
  static const relationEvidenceScene = 'relation.evidence_scene';
  static const relationEvidenceAdded = 'relation.evidence_added';
  static const relationChangedError = 'relation.changed_error';
  static const relationSaveFailed = 'relation.save_failed';
  static const relationHistoryFailed = 'relation.history_failed';
  static const relationNotFound = 'relation.not_found';
  static const relationRequired = 'relation.required';
  static const relationStatus = 'relation.status';
  static const relationType = 'relation.type';
  static const relationSource = 'relation.source';
  static const relationSwapEndpoints = 'relation.swap_endpoints';
  static const relationTarget = 'relation.target';
  static const relationCreate = 'relation.create';
  static const relationNoActive = 'relation.no_active';
  static const relationSaved = 'relation.saved';
  static const relationInvalidEvidence = 'relation.invalid_evidence';
  static const relationRefreshCurrent = 'relation.refresh_current';
  // ── relation_dialog ────────────────────────────────────────
  static const relationDialogEditLockNotice =
      'relation_dialog.edit_lock_notice';
  static const relationDialogErrorSelectRelationType =
      'relation_dialog.error_select_relation_type';
  static const relationDialogErrorSelectSource =
      'relation_dialog.error_select_source';
  static const relationDialogErrorSelectTarget =
      'relation_dialog.error_select_target';
  static const relationDialogHintNoSupportedTypes =
      'relation_dialog.hint_no_supported_types';
  static const relationDialogHintSelectTypesFirst =
      'relation_dialog.hint_select_types_first';
  static const relationDialogSectionRelation =
      'relation_dialog.section_relation';
  static const relationDialogSectionEvidence =
      'relation_dialog.section_evidence';
  static const relationDialogSectionSource = 'relation_dialog.section_source';
  static const relationDialogSectionTarget = 'relation_dialog.section_target';
  static const relationDialogEvidenceChapter =
      'relation_dialog.evidence_chapter';
  static const relationDialogEvidenceNoChapter =
      'relation_dialog.evidence_no_chapter';
  static const relationDialogStatusActive = 'relation_dialog.status_active';
  static const relationDialogStatusArchived = 'relation_dialog.status_archived';
  static const relationDialogSubtitleCreate = 'relation_dialog.subtitle_create';
  static const relationDialogSubtitleEdit = 'relation_dialog.subtitle_edit';
  // ── remote ────────────────────────────────────────
  static const remoteBridgeRunning = 'remote.bridge_running';
  static const remoteBridgeStart = 'remote.bridge_start';
  static const remoteBridgeStop = 'remote.bridge_stop';
  static const remoteBridgeStopped = 'remote.bridge_stopped';
  static const remoteConnected = 'remote.connected';
  static const remoteLastError = 'remote.last_error';
  static const remoteLoginCancel = 'remote.login_cancel';
  static const remoteLoginExpired = 'remote.login_expired';
  static const remoteLoginFailed = 'remote.login_failed';
  static const remoteLoginQrPrompt = 'remote.login_qr_prompt';
  static const remoteLoginScanned = 'remote.login_scanned';
  static const remoteLoginWechat = 'remote.login_wechat';
  static const remoteLogout = 'remote.logout';
  static const remoteNoInboundHandler = 'remote.no_inbound_handler';
  static const remoteSettingsDescription = 'remote.settings_description';
  static const remoteLoginFeatureTitle = 'remote.login_feature_title';
  static const remoteLoginFeatureDescription =
      'remote.login_feature_description';
  static const remoteLoginStep1 = 'remote.login_step_1';
  static const remoteLoginStep2 = 'remote.login_step_2';
  static const remoteLoginStep3 = 'remote.login_step_3';
  static const remoteLoginBadge = 'remote.login_badge';
  static const remoteRefreshQr = 'remote.refresh_qr';
  static const remoteConnectedStatus = 'remote.connected_status';
  static const remoteConnectedSubtitle = 'remote.connected_subtitle';
  static const remoteLastSync = 'remote.last_sync';
  static const remoteDeviceName = 'remote.device_name';
  // ── roleplay ────────────────────────────────────────
  static const roleplayDefaultTitle = 'roleplay.default_title';
  static const roleplayInputHint = 'roleplay.input_hint';
  static const roleplayNew = 'roleplay.new';
  static const roleplayNoCharacters = 'roleplay.no_characters';
  static const roleplaySelectCharacter = 'roleplay.select_character';
  static const roleplaySessionTitleFmt = 'roleplay.session_title_fmt';
  static const roleplaySpeakingFmt = 'roleplay.speaking_fmt';
  static const roleplayStart = 'roleplay.start';
  // ── settings ────────────────────────────────────────
  static const settingsAddCustomProvider = 'settings.add_custom_provider';
  static const settingsAddCustomProviderNameHint =
      'settings.add_custom_provider_name_hint';
  static const settingsAddCustomProviderNameLabel =
      'settings.add_custom_provider_name_label';
  static const settingsAddCustomProviderTitle =
      'settings.add_custom_provider_title';
  static const settingsAddCustomProviderTypeLabel =
      'settings.add_custom_provider_type_label';
  static const settingsAi = 'settings.ai';
  static const settingsAiAgentAvatar = 'settings.ai_agent_avatar';
  static const settingsAiAgentAvatarDescription =
      'settings.ai_agent_avatar_description';
  static const settingsAiAgentAvatarChange = 'settings.ai_agent_avatar_change';
  static const settingsAiAgentAvatarRemove = 'settings.ai_agent_avatar_remove';
  static const settingsAiAgentIdentity = 'settings.ai_agent_identity';
  static const settingsAiAgentIdentityDescription =
      'settings.ai_agent_identity_description';
  static const settingsAiAgentSoul = 'settings.ai_agent_soul';
  static const settingsAiAgentSoulDescription =
      'settings.ai_agent_soul_description';
  static const settingsAiAgentNextActionSuggestions =
      'settings.ai_agent_next_action_suggestions';
  static const settingsAiAgentNextActionSuggestionsDescription =
      'settings.ai_agent_next_action_suggestions_description';
  static const settingsAiAgents = 'settings.ai_agents';
  static const settingsAiAgentsDescription = 'settings.ai_agents_description';
  static const settingsAiAgentsSection = 'settings.ai_agents_section';
  static const settingsAiApiKey = 'settings.ai_api_key';
  static const settingsCodexCheckLogin = 'settings.codex_check_login';
  static const settingsCodexChecking = 'settings.codex_checking';
  static const settingsCodexAuthReady = 'settings.codex_auth_ready';
  static const settingsCodexAuthHint = 'settings.codex_auth_hint';
  static const settingsCodexAuthMissing = 'settings.codex_auth_missing';
  static const settingsCodexAuthInvalid = 'settings.codex_auth_invalid';
  static const settingsCodexAuthExpired = 'settings.codex_auth_expired';
  static const settingsCodexAuthRefreshFailed =
      'settings.codex_auth_refresh_failed';
  static const settingsCodexAuthWriteFailed =
      'settings.codex_auth_write_failed';
  static const settingsCodexAuthChanged = 'settings.codex_auth_changed';
  static const settingsCodexDesktopOnly = 'settings.codex_desktop_only';
  static const settingsAiApiKeyHint = 'settings.ai_api_key_hint';
  static const settingsAiBaseUrl = 'settings.ai_base_url';
  static const settingsAiBaseUrlHint = 'settings.ai_base_url_hint';
  static const settingsAiConfigDescription = 'settings.ai_config_description';
  static const settingsAiConfigInvalid = 'settings.ai_config_invalid';
  static const settingsAiConfigSection = 'settings.ai_config_section';
  static const settingsAiConfigValid = 'settings.ai_config_valid';
  static const settingsAiModel = 'settings.ai_model';
  static const settingsAiModelHint = 'settings.ai_model_hint';
  static const settingsAiProviderDescription =
      'settings.ai_provider_description';
  static const settingsAiProviderSection = 'settings.ai_provider_section';
  static const settingsAiTemperature = 'settings.ai_temperature';
  static const settingsAppearance = 'settings.appearance';
  static const settingsBackup = 'settings.backup';
  static const settingsBackupDescription = 'settings.backup_description';
  static const settingsBackupDescriptionNativeSave =
      'settings.backup_description_native_save';
  static const settingsBackupNativeSaveTitle =
      'settings.backup_native_save_title';
  static const settingsBackupNativeSaveHint =
      'settings.backup_native_save_hint';
  static const settingsBackupDirectory = 'settings.backup_directory';
  static const settingsBackupDirectoryHint = 'settings.backup_directory_hint';
  static const settingsBackupFailed = 'settings.backup_failed';
  static const settingsBackupFailedDatabaseUnreadable =
      'settings.backup_failed_database_unreadable';
  static const settingsBackupFailedDirectoryUnavailable =
      'settings.backup_failed_directory_unavailable';
  static const settingsBackupFailedWindowsPathUnsupported =
      'settings.backup_failed_windows_path_unsupported';
  static const settingsBackupFailedWebDav = 'settings.backup_failed_webdav';
  static const settingsBackupFrequency = 'settings.backup_frequency';
  static const settingsBackupFrequencyDaily = 'settings.backup_frequency_daily';
  static const settingsBackupFrequencyManual =
      'settings.backup_frequency_manual';
  static const settingsBackupFrequencyMonthly =
      'settings.backup_frequency_monthly';
  static const settingsBackupFrequencyWeekly =
      'settings.backup_frequency_weekly';
  static const settingsBackupDayOfMonth = 'settings.backup_day_of_month';
  static const settingsBackupTime = 'settings.backup_time';
  static const settingsBackupWeekdays = 'settings.backup_weekdays';
  static const settingsBackupWeekdayFriday = 'settings.backup_weekday_friday';
  static const settingsBackupWeekdayMonday = 'settings.backup_weekday_monday';
  static const settingsBackupWeekdaySaturday =
      'settings.backup_weekday_saturday';
  static const settingsBackupWeekdaySunday = 'settings.backup_weekday_sunday';
  static const settingsBackupWeekdayThursday =
      'settings.backup_weekday_thursday';
  static const settingsBackupWeekdayTuesday = 'settings.backup_weekday_tuesday';
  static const settingsBackupWeekdayWednesday =
      'settings.backup_weekday_wednesday';
  static const settingsBackupInProgress = 'settings.backup_in_progress';
  static const settingsBackupLastBackup = 'settings.backup_last_backup';
  static const settingsBackupNever = 'settings.backup_never';
  static const settingsBackupNow = 'settings.backup_now';
  static const settingsBackupSection = 'settings.backup_section';
  static const settingsBuiltinProviderAnthropic =
      'settings.builtin_provider_anthropic';
  static const settingsBuiltinProviderArk = 'settings.builtin_provider_ark';
  static const settingsBuiltinProviderDeepseek =
      'settings.builtin_provider_deepseek';
  static const settingsBuiltinProviderDoubao =
      'settings.builtin_provider_doubao';
  static const settingsBuiltinProviderGemini =
      'settings.builtin_provider_gemini';
  static const settingsBuiltinProviderMoonshot =
      'settings.builtin_provider_moonshot';
  static const settingsBuiltinProviderOpenai =
      'settings.builtin_provider_openai';
  static const settingsBuiltinProviderQwen = 'settings.builtin_provider_qwen';
  static const settingsBuiltinProviderXai = 'settings.builtin_provider_xai';
  static const settingsBuiltinProviderZhipu = 'settings.builtin_provider_zhipu';
  static const settingsDebugProviderDeepseekPartialTool =
      'settings.debug_provider_deepseek_partial_tool';
  static const settingsDebugProviderDeepseekTruncated =
      'settings.debug_provider_deepseek_truncated';
  static const settingsDebugProviderOpenaiResponsesPartialTool =
      'settings.debug_provider_openai_responses_partial_tool';
  static const settingsDebugProviderOpenaiResponsesThinkingOnly =
      'settings.debug_provider_openai_responses_thinking_only';
  static const settingsBackupSelectDirectory =
      'settings.backup_select_directory';
  static const settingsBackupSuccess = 'settings.backup_success';
  static const settingsBackupSuccessWithWarnings =
      'settings.backup_success_with_warnings';
  static const settingsBackupRestore = 'settings.backup_restore';
  static const settingsBackupRestoreConfirmTitle =
      'settings.backup_restore_confirm_title';
  static const settingsBackupRestoreConfirmMessage =
      'settings.backup_restore_confirm_message';
  static const settingsBackupRestoreConfirmRestore =
      'settings.backup_restore_confirm_restore';
  static const settingsBackupRestoreCancel = 'settings.backup_restore_cancel';
  static const settingsBackupRestoreClearAll =
      'settings.backup_restore_clear_all';
  static const settingsBackupRestoreConfirmFull =
      'settings.backup_restore_confirm_full';
  static const settingsBackupRestoreSuccess = 'settings.backup_restore_success';
  static const settingsBackupRestoreRestartTitle =
      'settings.backup_restore_restart_title';
  static const settingsBackupRestoreRestartMessage =
      'settings.backup_restore_restart_message';
  static const settingsBackupRestoreRestartExit =
      'settings.backup_restore_restart_exit';
  static const settingsBackupRestoreRestartAcknowledge =
      'settings.backup_restore_restart_acknowledge';
  static const settingsBackupRestoreFailed = 'settings.backup_restore_failed';
  static const settingsBackupRestoreFailedRolledBack =
      'settings.backup_restore_failed_rolled_back';
  static const settingsBackupRestoreFailedRollback =
      'settings.backup_restore_failed_rollback';
  static const settingsBackupRestoreFailedSafetyBackup =
      'settings.backup_restore_failed_safety_backup';
  static const settingsBackupRestoreFailedTitleConflict =
      'settings.backup_restore_failed_title_conflict';
  static const settingsBackupRestoreFailedUnsupported =
      'settings.backup_restore_failed_unsupported';
  static const settingsBackupRestoreInvalid = 'settings.backup_restore_invalid';
  static const settingsBackupRestoreInspecting =
      'settings.backup_restore_inspecting';
  static const settingsBackupRestoreInProgress =
      'settings.backup_restore_in_progress';
  static const settingsBackupRestoreModeFull =
      'settings.backup_restore_mode_full';
  static const settingsBackupRestoreModeFullDescription =
      'settings.backup_restore_mode_full_description';
  static const settingsBackupRestoreModeSelected =
      'settings.backup_restore_mode_selected';
  static const settingsBackupRestoreModeSelectedDescription =
      'settings.backup_restore_mode_selected_description';
  static const settingsBackupRestoreNovelConflict =
      'settings.backup_restore_novel_conflict';
  static const settingsBackupRestoreNovelImport =
      'settings.backup_restore_novel_import';
  static const settingsBackupRestoreNovelMissingContent =
      'settings.backup_restore_novel_missing_content';
  static const settingsBackupRestoreNovelOverwrite =
      'settings.backup_restore_novel_overwrite';
  static const settingsBackupRestorePreviewCreatedAt =
      'settings.backup_restore_preview_created_at';
  static const settingsBackupRestorePreviewNovels =
      'settings.backup_restore_preview_novels';
  static const settingsBackupRestorePreviewWarnings =
      'settings.backup_restore_preview_warnings';
  static const settingsBackupRestoreSelectAll =
      'settings.backup_restore_select_all';
  static const settingsBackupRestoreSelectNovels =
      'settings.backup_restore_select_novels';
  static const settingsWebDavTitle = 'settings.webdav_title';
  static const settingsWebDavDescription = 'settings.webdav_description';
  static const settingsWebDavEnable = 'settings.webdav_enable';
  static const settingsWebDavServerUrl = 'settings.webdav_server_url';
  static const settingsWebDavServerUrlHint = 'settings.webdav_server_url_hint';
  static const settingsWebDavUsername = 'settings.webdav_username';
  static const settingsWebDavPassword = 'settings.webdav_password';
  static const settingsWebDavRemoteDirectory =
      'settings.webdav_remote_directory';
  static const settingsWebDavSave = 'settings.webdav_save';
  static const settingsWebDavSaveAndTest = 'settings.webdav_save_and_test';
  static const settingsWebDavSaving = 'settings.webdav_saving';
  static const settingsWebDavSaved = 'settings.webdav_saved';
  static const settingsWebDavInvalidUrl = 'settings.webdav_invalid_url';
  static const settingsWebDavHttpWarning = 'settings.webdav_http_warning';
  static const settingsWebDavUsernameRequired =
      'settings.webdav_username_required';
  static const settingsWebDavPasswordRequired =
      'settings.webdav_password_required';
  static const settingsWebDavRemoteDirectoryInvalid =
      'settings.webdav_remote_directory_invalid';

  static const narrationTitle = 'screenplay.narration.title';
  static const narrationChooseVoice = 'screenplay.narration.chooseVoice';
  static const narrationUseNarrator = 'screenplay.narration.useNarrator';
  static const narrationHint = 'screenplay.narration.hint';
  static const narrationNoModels = 'screenplay.narration.noModels';
  static const narrationNoModelsHint = 'screenplay.narration.noModelsHint';
  static const narrationConfigure = 'screenplay.narration.configure';
  static const narrationModel = 'screenplay.narration.model';
  static const narrationChooseModel = 'screenplay.narration.chooseModel';
  static const narrationNarrator = 'screenplay.narration.narrator';
  static const narrationCharacters = 'screenplay.narration.characters';
  static const narrationInclude = 'screenplay.narration.include';
  static const narrationProgress = 'screenplay.narration.progress';
  static const narrationGenerating = 'screenplay.narration.generating';
  static const narrationComplete = 'screenplay.narration.complete';
  static const narrationPlaying = 'screenplay.narration.playing';
  static const narrationPaused = 'screenplay.narration.paused';
  static const narrationPrevious = 'screenplay.narration.previous';
  static const narrationNext = 'screenplay.narration.next';
  static const narrationSpeed = 'screenplay.narration.speed';
  static const narrationChangeVoices = 'screenplay.narration.changeVoices';
  static const narrationFailed = 'screenplay.narration.failed';
  static const narrationEmpty = 'screenplay.narration.empty';
  static const narrationMissingCharacter =
      'screenplay.narration.missingCharacter';
  static const narrationMissingScene = 'screenplay.narration.missingScene';
  static const narrationInvalidConfig = 'screenplay.narration.invalidConfig';
  static const narrationAuthentication = 'screenplay.narration.authentication';
  static const narrationRateLimited = 'screenplay.narration.rateLimited';

  static const screenplayAddBeat = 'screenplay.add_beat';
  static const screenplayAddEpisode = 'screenplay.add_episode';
  static const screenplayAddScene = 'screenplay.add_scene';
  static const screenplayAddSeason = 'screenplay.add_season';
  static const screenplayAct = 'screenplay.act';
  static const screenplayActNumber = 'screenplay.act_number';
  static const screenplayActualEpisodes = 'screenplay.actual_episodes';
  static const screenplayAddAct = 'screenplay.add_act';
  static const screenplayAppearanceMatrix = 'screenplay.appearance_matrix';
  static const screenplayAtLeastOneSeason = 'screenplay.at_least_one_season';
  static const screenplayAutosaveOn = 'screenplay.autosave_on';
  static const screenplayBeats = 'screenplay.beats';
  static const screenplayCastLine = 'screenplay.cast_line';
  static const screenplayCharacters = 'screenplay.characters';
  static const screenplayCharacterAppearances =
      'screenplay.character_appearances';
  static const screenplayCharacterInUse = 'screenplay.character_in_use';
  static const screenplayInUseMore = 'screenplay.in_use_more';
  static const screenplayLocationInUse = 'screenplay.location_in_use';
  static const screenplayCharacterList = 'screenplay.character_list';
  static const screenplayCharacterScenes = 'screenplay.character_scenes';
  static const screenplayCharacterName = 'screenplay.character_name';
  static const screenplayCharacterPlaceholder =
      'screenplay.character_placeholder';
  static const screenplayCreateCharacterNamed =
      'screenplay.create_character_named';
  static const screenplaySwitchToAction = 'screenplay.switch_to_action';
  static const screenplayOriginal = 'screenplay.original';
  static const screenplayAdaptedFrom = 'screenplay.adapted_from';
  static const screenplaySequelTo = 'screenplay.sequel_to';
  static const screenplayFanficOf = 'screenplay.fanfic_of';
  static const screenplayDerivedFrom = 'screenplay.derived_from';
  static const screenplaySourceFrom = 'screenplay.source_from';
  static const screenplaySourceUnavailable = 'screenplay.source_unavailable';
  static const screenplayViewSource = 'screenplay.view_source';
  static const screenplayContinueWriting = 'screenplay.continue_writing';
  static const screenplayConfirmDelete = 'screenplay.confirm_delete';
  static const screenplayDeleteScenePrompt = 'screenplay.delete_scene_prompt';
  static const screenplayCurrentSceneCharacters =
      'screenplay.current_scene_characters';
  static const screenplayDeleteDialogueBlock =
      'screenplay.delete_dialogue_block';
  static const screenplayDialogueLines = 'screenplay.dialogue_lines';
  static const screenplayDialogueWordCount = 'screenplay.dialogue_word_count';
  static const screenplayDraft = 'screenplay.draft';
  static const screenplayEachSeason = 'screenplay.each_season';
  static const screenplayEditScene = 'screenplay.edit_scene';
  static const screenplayEditScript = 'screenplay.edit_script';
  static const screenplayEditSeason = 'screenplay.edit_season';
  static const screenplayElementAction = 'screenplay.element_action';
  static const screenplayElementCharacter = 'screenplay.element_character';
  static const screenplayElementDialogue = 'screenplay.element_dialogue';
  static const screenplayElementHintEnter = 'screenplay.element_hint_enter';
  static const screenplayElementHintTab = 'screenplay.element_hint_tab';
  static const screenplayElementNote = 'screenplay.element_note';
  static const screenplayElementParenthetical =
      'screenplay.element_parenthetical';
  static const screenplayElementScene = 'screenplay.element_scene';
  static const screenplayElementSubtitle = 'screenplay.element_subtitle';
  static const screenplayElementTransition = 'screenplay.element_transition';
  static const screenplayEnterSeason = 'screenplay.enter_season';
  static const screenplayEpisode = 'screenplay.episode';
  static const screenplayEpisodeCount = 'screenplay.episode_count';
  static const screenplayEpisodeMove = 'screenplay.episode_move';
  static const screenplayEpisodeMoveBlocked = 'screenplay.episode_move_blocked';
  static const screenplayEpisodes = 'screenplay.episodes';
  static const screenplayExterior = 'screenplay.exterior';
  static const screenplayFinal = 'screenplay.final';
  static const screenplayStructureChange = 'screenplay.structure_change';
  static const screenplayStructureImpact = 'screenplay.structure_impact';
  static const screenplayStaleEdit = 'screenplay.stale_edit';
  static const screenplayReloadDraft = 'screenplay.reload_draft';
  static const screenplayKeepDraft = 'screenplay.keep_draft';
  static const screenplayCopyDraft = 'screenplay.copy_draft';
  static const screenplayFirstHeadingRequired =
      'screenplay.first_heading_required';
  static const screenplayStartWriting = 'screenplay.start_writing';
  static const screenplayEditHeading = 'screenplay.edit_heading';
  static const screenplayUndo = 'screenplay.undo';
  static const screenplayRedo = 'screenplay.redo';
  static const screenplayHistoryInvalid = 'screenplay.history_invalid';
  static const screenplayStatisticsPending = 'screenplay.statistics_pending';
  static const screenplayHeadingMatchesSkipped =
      'screenplay.heading_matches_skipped';
  static const screenplayInterior = 'screenplay.interior';
  static const screenplayInteriorExterior = 'screenplay.interior_exterior';
  static const screenplayLastEpisodeInSeason =
      'screenplay.last_episode_in_season';
  static const screenplayLength = 'screenplay.length';
  static const screenplayLinesUnit = 'screenplay.lines_unit';
  static const screenplayLocations = 'screenplay.locations';
  static const screenplayPlaces = 'screenplay.places';
  static const screenplayUnitBeats = 'screenplay.unit_beats';
  static const screenplayUnitEpisodes = 'screenplay.unit_episodes';
  static const screenplayUnitLines = 'screenplay.unit_lines';
  static const screenplayUnitPeople = 'screenplay.unit_people';
  static const screenplayUnitPlaces = 'screenplay.unit_places';
  static const screenplayUnitScenes = 'screenplay.unit_scenes';
  static const screenplayUnitSeasons = 'screenplay.unit_seasons';
  static const screenplayLocationName = 'screenplay.location_name';
  static const screenplayManageSeasons = 'screenplay.manage_seasons';
  static const screenplayMatrixHint = 'screenplay.matrix_hint';
  static const screenplayMoveDown = 'screenplay.move_down';
  static const screenplayMoveUp = 'screenplay.move_up';
  static const screenplayNoBeats = 'screenplay.no_beats';
  static const screenplayNoCharacters = 'screenplay.no_characters';
  static const screenplayNoOutline = 'screenplay.no_outline';
  static const screenplayNoScenes = 'screenplay.no_scenes';
  static const screenplayNoScenesSub = 'screenplay.no_scenes_sub';
  static const screenplayNoScriptYet = 'screenplay.no_script_yet';
  static const screenplayNotePrefix = 'screenplay.note_prefix';
  static const screenplayOpenBeatsBoard = 'screenplay.open_beats_board';
  static const screenplayOutline = 'screenplay.outline';
  static const screenplayOutlineBeats = 'screenplay.outline_beats';
  static const screenplayOutlineHint = 'screenplay.outline_hint';
  static const screenplayWriteFromSynopsis = 'screenplay.write_from_synopsis';
  static const screenplayOverPlanned = 'screenplay.over_planned';
  static const screenplayOverview = 'screenplay.overview';
  static const screenplayPagesEstimated = 'screenplay.pages_estimated';
  static const screenplayPagesUnit = 'screenplay.pages_unit';
  static const screenplayPeopleUnit = 'screenplay.people_unit';
  static const screenplayPlannedEpisodes = 'screenplay.planned_episodes';
  static const screenplayQuickCreateCharacter =
      'screenplay.quick_create_character';
  static const screenplayQuickCreateLocation =
      'screenplay.quick_create_location';
  static const screenplayRelations = 'screenplay.relations';
  static const screenplayRenameSeason = 'screenplay.rename_season';
  static const screenplayOpening = 'screenplay.opening';
  static const screenplaySaveFailed = 'screenplay.save_failed';
  static const screenplayScene = 'screenplay.scene';
  static const screenplaySceneAppearance = 'screenplay.scene_appearance';
  static const screenplaySceneCards = 'screenplay.scene_cards';
  static const screenplaySceneCount = 'screenplay.scene_count';
  static const screenplaySceneList = 'screenplay.scene_list';
  static const screenplayScenes = 'screenplay.scenes';
  static const screenplayScopeSeason = 'screenplay.scope_season';
  static const screenplayScopeSeries = 'screenplay.scope_series';
  static const screenplayScript = 'screenplay.script';
  static const screenplayStage = 'screenplay.stage';
  static const screenplayStoryIntro = 'screenplay.story_intro';
  static const screenplaySeason = 'screenplay.season';
  static const screenplaySeasonPicker = 'screenplay.season_picker';
  static const screenplaySeasons = 'screenplay.seasons';
  static const screenplaySeasonCount = 'screenplay.season_count';
  static const screenplaySeasonTitle = 'screenplay.season_title';
  static const screenplaySeries = 'screenplay.series';
  static const screenplaySynopsis = 'screenplay.synopsis';
  static const screenplayTime = 'screenplay.time';
  static const screenplayTimeDay = 'screenplay.time_day';
  static const screenplayTimeNight = 'screenplay.time_night';
  static const screenplayTimeNoon = 'screenplay.time_noon';
  static const screenplayTimeMorning = 'screenplay.time_morning';
  static const screenplayTimeAfternoon = 'screenplay.time_afternoon';
  static const screenplayTimeDusk = 'screenplay.time_dusk';
  static const screenplayTimeLateNight = 'screenplay.time_late_night';
  static const screenplayTimeContinuous = 'screenplay.time_continuous';
  static const screenplayTimeLater = 'screenplay.time_later';
  static const screenplayTimeSameTime = 'screenplay.time_same_time';
  static const screenplayTimeHint = 'screenplay.time_hint';
  static const screenplayUntitledBeat = 'screenplay.untitled_beat';
  static const screenplayUntitledEpisode = 'screenplay.untitled_episode';
  static const screenplayUntitledScene = 'screenplay.untitled_scene';
  static const screenplayDeletedCharacter = 'screenplay.deleted_character';
  static const screenplayDeletedLocation = 'screenplay.deleted_location';
  static const screenplayMissingReferenceHint =
      'screenplay.missing_reference_hint';
  static const screenplayUnknownCharacter = 'screenplay.unknown_character';
  static const screenplayWords = 'screenplay.words';
  static const settingsWebDavConnectionFailed =
      'settings.webdav_connection_failed';
  static const settingsWebDavUnauthorized = 'settings.webdav_unauthorized';
  static const settingsWebDavSaveFailed = 'settings.webdav_save_failed';
  static const settingsWebDavRestore = 'settings.webdav_restore';
  static const settingsWebDavRestoreTitle = 'settings.webdav_restore_title';
  static const settingsWebDavRestoreDescription =
      'settings.webdav_restore_description';
  static const settingsWebDavRestoreLoading = 'settings.webdav_restore_loading';
  static const settingsWebDavRestoreEmpty = 'settings.webdav_restore_empty';
  static const settingsWebDavRestoreFailed = 'settings.webdav_restore_failed';
  static const settingsWebDavRestoreRetry = 'settings.webdav_restore_retry';
  static const settingsWebDavRestoreDownload =
      'settings.webdav_restore_download';
  static const settingsWebDavRestoreDownloading =
      'settings.webdav_restore_downloading';
  static const settingsChangeRecordRetention =
      'settings.change_record_retention';
  static const settingsChangeRecordRetentionDays =
      'settings.change_record_retention_days';
  static const settingsChineseSimplified = 'settings.chinese_simplified';
  static const settingsCustomBadge = 'settings.custom_badge';
  static const settingsDeleteProviderConfirm =
      'settings.delete_provider_confirm';
  static const settingsRemote = 'settings.remote';
  static const settingsFonts = 'settings.fonts';
  static const settingsFontsSection = 'settings.fonts_section';
  static const settingsFontsDescription = 'settings.fonts_description';
  static const settingsEditorFont = 'settings.editor_font';
  static const settingsEditorFontDescription =
      'settings.editor_font_description';
  static const settingsEditorFontsLoading = 'settings.editor_fonts_loading';
  static const settingsEditorFontsUnavailable =
      'settings.editor_fonts_unavailable';
  static const settingsEditorFontColor = 'settings.editor_font_color';
  static const settingsEditorFontColorDescription =
      'settings.editor_font_color_description';
  static const settingsEditorFontSize = 'settings.editor_font_size';
  static const settingsEditorFontSizeDescription =
      'settings.editor_font_size_description';
  static const settingsEditorLetterSpacing = 'settings.editor_letter_spacing';
  static const settingsEditorLetterSpacingDescription =
      'settings.editor_letter_spacing_description';
  static const settingsEditorLineHeight = 'settings.editor_line_height';
  static const settingsEditorLineHeightDescription =
      'settings.editor_line_height_description';
  static const settingsEditorMinimap = 'settings.editor_minimap';
  static const settingsEditorMinimapDescription =
      'settings.editor_minimap_description';
  static const settingsEditorLineNumbers = 'settings.editor_line_numbers';
  static const settingsEditorLineNumbersDescription =
      'settings.editor_line_numbers_description';
  static const settingsEditorLine = 'settings.editor_line';
  static const settingsEditorLineDescription =
      'settings.editor_line_description';
  static const settingsEditorLineEnabled = 'settings.editor_line_enabled';
  static const settingsEditorLineStyle = 'settings.editor_line_style';
  static const settingsEditorLineStyleSolid =
      'settings.editor_line_style_solid';
  static const settingsEditorLineStyleSparseDashed =
      'settings.editor_line_style_sparse_dashed';
  static const settingsEditorLineStyleDenseDashed =
      'settings.editor_line_style_dense_dashed';
  static const settingsEditorLineColor = 'settings.editor_line_color';
  static const settingsEditorColorInvalid = 'settings.editor_color_invalid';
  static const settingsEditorEntityStyle = 'settings.editor_entity_style';
  static const settingsEditorEntityStyleDescription =
      'settings.editor_entity_style_description';
  static const settingsEditorEntityItalic = 'settings.editor_entity_italic';
  static const settingsEditorEntityHighlight =
      'settings.editor_entity_highlight';
  static const settingsEditorEntityHighlightColor =
      'settings.editor_entity_highlight_color';
  static const settingsEditorEntityTextColor =
      'settings.editor_entity_text_color';
  static const settingsEditorEntityTextColorDescription =
      'settings.editor_entity_text_color_description';
  static const settingsEditorEntityUnderline =
      'settings.editor_entity_underline';
  static const settingsEditorEntityBold = 'settings.editor_entity_bold';
  static const settingsEditorFormat = 'settings.editor_format';
  static const settingsEditorFormatDescription =
      'settings.editor_format_description';
  static const settingsEditorFormatIndentCount =
      'settings.editor_format_indent_count';
  static const settingsEditorFormatIndentCountDescription =
      'settings.editor_format_indent_count_description';
  static const settingsEditorFormatParagraphSpacing =
      'settings.editor_format_paragraph_spacing';
  static const settingsEditorFormatParagraphSpacingDescription =
      'settings.editor_format_paragraph_spacing_description';
  static const settingsEditorFormatParagraphSpacingNone =
      'settings.editor_format_paragraph_spacing_none';
  static const settingsEditorFormatParagraphSpacingOneBlankLine =
      'settings.editor_format_paragraph_spacing_one_blank_line';
  static const settingsEditorFormatAllowSpaces =
      'settings.editor_format_allow_spaces';
  static const settingsEditorFormatAllowSpacesDescription =
      'settings.editor_format_allow_spaces_description';
  static const settingsReading = 'settings.reading';
  static const settingsReadingDescription = 'settings.reading_description';
  static const settingsReadingSection = 'settings.reading_section';
  static const settingsReadingSectionDescription =
      'settings.reading_section_description';
  static const settingsReadingFont = 'settings.reading_font';
  static const settingsReadingFontDescription =
      'settings.reading_font_description';
  static const settingsReadingFontSize = 'settings.reading_font_size';
  static const settingsReadingFontSizeDescription =
      'settings.reading_font_size_description';
  static const settingsReadingLetterSpacing = 'settings.reading_letter_spacing';
  static const settingsReadingLetterSpacingDescription =
      'settings.reading_letter_spacing_description';
  static const settingsReadingLineHeight = 'settings.reading_line_height';
  static const settingsReadingLineHeightDescription =
      'settings.reading_line_height_description';
  static const settingsReadingParagraphSpacing =
      'settings.reading_paragraph_spacing';
  static const settingsReadingParagraphSpacingDescription =
      'settings.reading_paragraph_spacing_description';
  static const settingsReadingMargin = 'settings.reading_margin';
  static const settingsReadingMarginDescription =
      'settings.reading_margin_description';
  static const settingsReadingBackgroundTheme =
      'settings.reading_background_theme';
  static const settingsReadingBackgroundThemeDescription =
      'settings.reading_background_theme_description';
  static const settingsReadingBackgroundThemeWhite =
      'settings.reading_background_theme_white';
  static const settingsReadingBackgroundThemeSepia =
      'settings.reading_background_theme_sepia';
  static const settingsReadingBackgroundThemeCream =
      'settings.reading_background_theme_cream';
  static const settingsReadingBackgroundThemeEyeCare =
      'settings.reading_background_theme_eye_care';
  static const settingsReadingBackgroundThemeDark =
      'settings.reading_background_theme_dark';
  static const settingsReadingBackgroundThemeNight =
      'settings.reading_background_theme_night';
  static const settingsReadingPageTransition =
      'settings.reading_page_transition';
  static const settingsReadingPageTransitionDescription =
      'settings.reading_page_transition_description';
  static const settingsReadingPageTransitionScroll =
      'settings.reading_page_transition_scroll';
  static const settingsReadingPageTransitionHorizontal =
      'settings.reading_page_transition_horizontal';
  static const settingsReadingPageTransitionFade =
      'settings.reading_page_transition_fade';
  static const settingsReadingBold = 'settings.reading_bold';
  static const settingsReadingBoldDescription =
      'settings.reading_bold_description';
  static const settingsReadingResetTypography =
      'settings.reading_reset_typography';
  static const settingsReadingGroupTypography =
      'settings.reading_group_typography';
  static const settingsReadingGroupLayout = 'settings.reading_group_layout';
  static const settingsReadingGroupExperience =
      'settings.reading_group_experience';
  static const settingsReadingPageTurn = 'settings.reading_page_turn';
  static const settingsDesktopReadingChapter =
      'settings.desktop_reading_chapter';
  static const settingsDesktopReadingContinuousScroll =
      'settings.desktop_reading_continuous_scroll';
  static const settingsMobileReadingScroll = 'settings.mobile_reading_scroll';
  static const settingsMobileReadingHorizontal =
      'settings.mobile_reading_horizontal';
  static const settingsAppBackground = 'settings.app_background';
  static const settingsAppBackgroundDescription =
      'settings.app_background_description';
  static const settingsAppBackgroundColor = 'settings.app_background_color';
  static const settingsAppBackgroundImage = 'settings.app_background_image';
  static const settingsAppBackgroundNone = 'settings.app_background_none';
  static const settingsAppBackgroundBuiltin = 'settings.app_background_builtin';
  static const settingsAppBackgroundCustom = 'settings.app_background_custom';
  static const settingsAppBackgroundBuiltinActive =
      'settings.app_background_builtin_active';
  static const settingsAppBackgroundCustomActive =
      'settings.app_background_custom_active';
  static const settingsAppBackgroundBuiltinPaper =
      'settings.app_background_builtin_paper';
  static const settingsAppBackgroundBuiltinDistantMountains =
      'settings.app_background_builtin_distant_mountains';
  static const settingsAppBackgroundBuiltinStarrySky =
      'settings.app_background_builtin_starry_sky';
  static const settingsAppBackgroundBuiltinMagnificent =
      'settings.app_background_builtin_magnificent';
  static const settingsAppBackgroundBuiltinWitheredTree =
      'settings.app_background_builtin_withered_tree';
  static const settingsAppBackgroundBuiltinPlumBlossom =
      'settings.app_background_builtin_plum_blossom';
  static const settingsAppBackgroundBuiltinSolitaryBoat =
      'settings.app_background_builtin_solitary_boat';
  static const settingsAppBackgroundFit = 'settings.app_background_fit';
  static const settingsAppBackgroundFitCover =
      'settings.app_background_fit_cover';
  static const settingsAppBackgroundFitContain =
      'settings.app_background_fit_contain';
  static const settingsAppBackgroundFitFill =
      'settings.app_background_fit_fill';
  static const settingsAppBackgroundSelect = 'settings.app_background_select';
  static const settingsAppBackgroundRemove = 'settings.app_background_remove';
  static const settingsAppBackgroundEmpty = 'settings.app_background_empty';
  static const settingsAppBackgroundImageInactive =
      'settings.app_background_image_inactive';
  static const settingsAppBackgroundFailed = 'settings.app_background_failed';
  static const settingsEnglish = 'settings.english';
  static const settingsGeneral = 'settings.general';
  static const settingsGroupAi = 'settings.group_ai';
  static const settingsGroupData = 'settings.group_data';
  static const settingsGroupPreferences = 'settings.group_preferences';
  static const settingsGroupSystem = 'settings.group_system';
  static const settingsLanguage = 'settings.language';
  static const settingsLanguageDescription = 'settings.language_description';
  static const settingsProxyTitle = 'settings.proxy.title';
  static const settingsProxyDescription = 'settings.proxy.description';
  static const settingsProxyMode = 'settings.proxy.mode';
  static const settingsProxyDirect = 'settings.proxy.direct';
  static const settingsProxyEnvironment = 'settings.proxy.environment';
  static const settingsProxyCustom = 'settings.proxy.custom';
  static const settingsProxyAddress = 'settings.proxy.address';
  static const settingsProxyAddressHint = 'settings.proxy.address_hint';
  static const settingsProxyUsername = 'settings.proxy.username';
  static const settingsProxyPassword = 'settings.proxy.password';
  static const settingsProxyCredentialHint = 'settings.proxy.credential_hint';
  static const settingsProxyCredentialsIncomplete =
      'settings.proxy.credentials_incomplete';
  static const settingsProxyUsernameInvalid = 'settings.proxy.username_invalid';
  static const settingsProxyPasswordInvalid = 'settings.proxy.password_invalid';
  static const settingsProxyCredentialTooLong =
      'settings.proxy.credential_too_long';
  static const settingsProxyInvalidUrl = 'settings.proxy.invalid_url';
  static const settingsProxyLoadFailed = 'settings.proxy.load_failed';
  static const settingsLanguageSection = 'settings.language_section';
  static const settingsPrivacySection = 'settings.privacy_section';
  static const settingsPrivacyDescription = 'settings.privacy_description';
  static const settingsAnonymousReporting = 'settings.anonymous_reporting';
  static const settingsAnonymousReportingDescription =
      'settings.anonymous_reporting_description';
  static const settingsModelDefaultsUnset = 'settings.model_defaults_unset';
  static const settingsProviderChatModelsHint =
      'settings.provider_chat_models_hint';
  static const settingsProviderChatModelsLabel =
      'settings.provider_chat_models_label';
  static const settingsProviderConfigNeedApiKey =
      'settings.provider_config_need_api_key';
  static const settingsProviderConfigNeedBaseUrl =
      'settings.provider_config_need_base_url';
  static const settingsProviderConfigNeedModels =
      'settings.provider_config_need_models';
  static const settingsProviderFetchModels = 'settings.provider_fetch_models';
  static const settingsProviderBaseUrlEndpointHint =
      'settings.provider_base_url_endpoint_hint';
  static const settingsProviderFetchModelsBadRequest =
      'settings.provider_fetch_models_bad_request';
  static const settingsProviderFetchModelsAuthFailed =
      'settings.provider_fetch_models_auth_failed';
  static const settingsProviderFetchModelsNotFound =
      'settings.provider_fetch_models_not_found';
  static const settingsProviderFetchModelsRateLimited =
      'settings.provider_fetch_models_rate_limited';
  static const settingsProviderFetchModelsServerError =
      'settings.provider_fetch_models_server_error';

  static const settingsProviderFetchModelsNoMatches =
      'settings.provider_fetch_models_no_matches';
  static const settingsProviderFetchModelsSearchHint =
      'settings.provider_fetch_models_search_hint';
  static const settingsProviderEmbeddingModelsHint =
      'settings.provider_embedding_models_hint';
  static const settingsProviderEmbeddingModelsLabel =
      'settings.provider_embedding_models_label';
  static const settingsProviderImageModelsHint =
      'settings.provider_image_models_hint';
  static const settingsProviderImageModelsLabel =
      'settings.provider_image_models_label';
  static const settingsProviderNameHint = 'settings.provider_name_hint';
  static const settingsProviderNameLabel = 'settings.provider_name_label';
  static const settingsProviderNoModelsYet = 'settings.provider_no_models_yet';
  static const settingsProviderProxyPasswordHint =
      'settings.provider_proxy_password_hint';
  static const settingsProviderProxyPasswordLabel =
      'settings.provider_proxy_password_label';
  static const settingsProviderProxySection = 'settings.provider_proxy_section';
  static const settingsProviderProxyUrlHint =
      'settings.provider_proxy_url_hint';
  static const settingsProviderProxyUrlLabel =
      'settings.provider_proxy_url_label';
  static const settingsProviderProxyUsernameHint =
      'settings.provider_proxy_username_hint';
  static const settingsProviderProxyUsernameLabel =
      'settings.provider_proxy_username_label';
  static const settingsProviderSelectPlaceholder =
      'settings.provider_select_placeholder';
  static const settingsProviderTypeLabel = 'settings.provider_type_label';
  static const settingsProviderUnsupportedBadge =
      'settings.provider_unsupported_badge';
  static const settingsProviderTypeUnsupported =
      'settings.provider_type_unsupported';
  static const settingsProviderTypeOpenaiCompatible =
      'settings.provider_type_openai_compatible';
  static const settingsProfileSubtitle = 'settings.profile_subtitle';
  static const settingsProviders = 'settings.providers';
  static const settingsProvidersSummary = 'settings.providers_summary';
  static const settingsReasoningEffort = 'settings.reasoning_effort';
  static const settingsReasoningEffortDefault =
      'settings.reasoning_effort_default';
  static const settingsReasoningEffortHigh = 'settings.reasoning_effort_high';
  static const settingsReasoningEffortLow = 'settings.reasoning_effort_low';
  static const settingsReasoningEffortMedium =
      'settings.reasoning_effort_medium';
  static const settingsReasoningEffortNone = 'settings.reasoning_effort_none';
  static const settingsStatusActive = 'settings.status_active';
  static const settingsStatusInactive = 'settings.status_inactive';
  static const settingsStorage = 'settings.storage';
  static const settingsFileWorkspaceDirectory =
      'settings.file_workspace_directory';
  static const settingsFileWorkspaceHint = 'settings.file_workspace_hint';
  static const settingsFileWorkspaceCurrent = 'settings.file_workspace_current';
  static const settingsFileWorkspaceTarget = 'settings.file_workspace_target';
  static const settingsFileWorkspaceTargetHint =
      'settings.file_workspace_target_hint';
  static const settingsFileWorkspaceMigrateHint =
      'settings.file_workspace_migrate_hint';
  static const settingsFileWorkspaceMigrate = 'settings.file_workspace_migrate';
  static const settingsFileWorkspaceMigrating =
      'settings.file_workspace_migrating';
  static const settingsFileWorkspaceLoadFailed =
      'settings.file_workspace_load_failed';
  static const settingsFileWorkspaceSaveFailed =
      'settings.file_workspace_save_failed';
  static const settingsFileWorkspaceStartupFailed =
      'settings.file_workspace_startup_failed';
  static const settingsFileWorkspaceStartupFailedHint =
      'settings.file_workspace_startup_failed_hint';
  static const settingsFileWorkspaceMigrationFailed =
      'settings.file_workspace_migration_failed';
  static const settingsFileWorkspaceMigrationFailedHint =
      'settings.file_workspace_migration_failed_hint';
  static const settingsFileWorkspaceUseDefault =
      'settings.file_workspace_use_default';
  static const settingsFileWorkspaceRecoveryHint =
      'settings.file_workspace_recovery_hint';
  static const settingsObjectStorageTitle = 'settings.object_storage_title';

  static const settingsStorageDescription = 'settings.storage_description';
  static const settingsBackupPageDescription =
      'settings.backup_page_description';
  static const settingsObjectStorageProvider =
      'settings.object_storage_provider';
  static const settingsObjectStorageProviderS3 =
      'settings.object_storage_provider_s3';
  static const settingsObjectStorageProviderS3Hint =
      'settings.object_storage_provider_s3_hint';
  static const settingsObjectStorageEndpoint =
      'settings.object_storage_endpoint';
  static const settingsObjectStorageEndpointHint =
      'settings.object_storage_endpoint_hint';
  static const settingsObjectStorageRegion = 'settings.object_storage_region';
  static const settingsObjectStorageRegionHint =
      'settings.object_storage_region_hint';
  static const settingsObjectStorageBucket = 'settings.object_storage_bucket';
  static const settingsObjectStorageAccessKeyId =
      'settings.object_storage_access_key_id';
  static const settingsObjectStorageSecretAccessKey =
      'settings.object_storage_secret_access_key';
  static const settingsObjectStorageKeyPrefix =
      'settings.object_storage_key_prefix';
  static const settingsObjectStoragePathStyle =
      'settings.object_storage_path_style';
  static const settingsObjectStoragePathStyleHint =
      'settings.object_storage_path_style_hint';
  static const settingsObjectStoragePublicBaseUrl =
      'settings.object_storage_public_base_url';
  static const settingsObjectStoragePublicBaseUrlHint =
      'settings.object_storage_public_base_url_hint';
  static const settingsObjectStorageSaveAndTest =
      'settings.object_storage_save_and_test';
  static const settingsObjectStorageTesting = 'settings.object_storage_testing';
  static const settingsObjectStorageSaved = 'settings.object_storage_saved';
  static const settingsObjectStorageSaveFailed =
      'settings.object_storage_save_failed';
  static const settingsObjectStorageInvalidUrl =
      'settings.object_storage_invalid_url';
  static const settingsObjectStorageInvalidKeyPrefix =
      'settings.object_storage_invalid_key_prefix';
  static const settingsObjectStorageConnectionFailed =
      'settings.object_storage_connection_failed';
  static const settingsObjectStorageUnauthorized =
      'settings.object_storage_unauthorized';
  static const settingsObjectStorageBucketNotFound =
      'settings.object_storage_bucket_not_found';
  static const settingsObjectStorageUploadFailed =
      'settings.object_storage_upload_failed';
  static const settingsObjectStorageReadFailed =
      'settings.object_storage_read_failed';
  static const settingsThemeClassic = 'settings.theme_classic';
  static const settingsThemeClassicDescription =
      'settings.theme_classic_description';
  static const settingsThemeIvory = 'settings.theme_ivory';
  static const settingsThemeIvoryDescription =
      'settings.theme_ivory_description';
  static const settingsThemeDescription = 'settings.theme_description';
  static const settingsThemeReveric = 'settings.theme_reveric';
  static const settingsThemeRevericDescription =
      'settings.theme_reveric_description';
  static const settingsThemeModeDark = 'settings.theme_mode_dark';
  static const settingsThemeModeDescription = 'settings.theme_mode_description';
  static const settingsThemeModeLight = 'settings.theme_mode_light';
  static const settingsThemeModeSection = 'settings.theme_mode_section';
  static const settingsThemeModeSystem = 'settings.theme_mode_system';
  static const settingsUiTextScaleDescription =
      'settings.ui_text_scale_description';
  static const settingsUiTextScaleExtraLarge =
      'settings.ui_text_scale_extra_large';
  static const settingsUiTextScaleLarge = 'settings.ui_text_scale_large';
  static const settingsUiTextScaleSection = 'settings.ui_text_scale_section';
  static const settingsUiTextScaleSmall = 'settings.ui_text_scale_small';
  static const settingsUiTextScaleStandard = 'settings.ui_text_scale_standard';
  static const settingsCustomThemes = 'settings.custom_themes';
  static const settingsCustomThemesLoadError =
      'settings.custom_themes_load_error';
  static const settingsCustomThemeApplyError =
      'settings.custom_theme_apply_error';
  static const settingsThemeSection = 'settings.theme_section';
  static const settingsTaglineFooter = 'settings.tagline_footer';
  static const settingsTitle = 'settings.title';
  static const settingsAbout = 'settings.about';
  static const settingsAboutVersion = 'settings.about_version';
  static const settingsAboutUpdates = 'settings.about_updates';
  static const settingsAboutUpdatesDescription =
      'settings.about_updates_description';
  static const settingsAboutCheckForUpdates =
      'settings.about_check_for_updates';
  static const settingsAboutCheckingUpdates = 'settings.about_checking_updates';
  static const settingsAboutUpToDate = 'settings.about_up_to_date';
  static const settingsDebugTriggerUpdateReminder =
      'settings.debug_trigger_update_reminder';
  static const settingsDebugTriggerUpdateReminderDescription =
      'settings.debug_trigger_update_reminder_description';
  static const settingsUpdateReleased = 'settings.update_released';
  static const settingsUpdateView = 'settings.update_view';
  static const settingsUpdateEntry = 'settings.update_entry';
  static const settingsAboutUpdateAvailable = 'settings.about_update_available';
  static const settingsAboutDownloadUpdate = 'settings.about_download_update';
  static const settingsAboutDownloadingProgress =
      'settings.about_downloading_progress';
  static const settingsAboutApplyingUpdate = 'settings.about_applying_update';
  static const settingsAboutInstallUpdate = 'settings.about_install_update';
  static const settingsAboutRestartToUpdate =
      'settings.about_restart_to_update';
  static const settingsAboutCheckFailed = 'settings.about_check_failed';
  static const settingsAboutUpdateApplyFailed =
      'settings.about_update_apply_failed';
  static const settingsAboutUpdateAppBundleMissing =
      'settings.about_update_app_bundle_missing';
  static const settingsAboutUpdateDownloadFailed =
      'settings.about_update_download_failed';
  static const settingsAboutUpdateDownloadedFileMissing =
      'settings.about_update_downloaded_file_missing';
  static const settingsAboutUpdateExtractionFailed =
      'settings.about_update_extraction_failed';
  static const settingsAboutUpdateInvalidPackage =
      'settings.about_update_invalid_package';
  static const settingsAboutUpdatePrepareFailed =
      'settings.about_update_prepare_failed';
  static const settingsAboutUpdateReplaceFailed =
      'settings.about_update_replace_failed';
  static const settingsAboutUpdateUnsupportedPlatform =
      'settings.about_update_unsupported_platform';
  static const settingsAboutOpenLogs = 'settings.about_open_logs';
  static const settingsAboutOpenLogsDescription =
      'settings.about_open_logs_description';
  static const settingsAboutOpenStorageFailed =
      'settings.about_open_storage_failed';
  static const settingsAboutFeedback = 'settings.about_feedback';
  static const settingsAboutFeedbackDescription =
      'settings.about_feedback_description';
  static const settingsAboutOpenIssues = 'settings.about_open_issues';
  static const settingsAboutOpenIssuesFailed =
      'settings.about_open_issues_failed';
  static const settingsAboutOpenSource = 'settings.about_open_source';
  static const settingsAboutOpenSourceDescription =
      'settings.about_open_source_description';
  static const settingsAboutOpenRepositoryFailed =
      'settings.about_open_repository_failed';
  static const settingsDebug = 'settings.debug';
  static const settingsDebugDescription = 'settings.debug_description';
  static const settingsDebugCloseSection = 'settings.debug_close_section';
  static const settingsDebugMode = 'settings.debug_mode';
  static const settingsDebugModeDescription = 'settings.debug_mode_description';
  static const settingsDebugResetOnboarding = 'settings.debug_reset_onboarding';
  static const settingsDebugResetOnboardingDescription =
      'settings.debug_reset_onboarding_description';
  static const settingsDebugResetOnboardingButton =
      'settings.debug_reset_onboarding_button';
  static const settingsDebugResetOnboardingSuccess =
      'settings.debug_reset_onboarding_success';
  static const settingsDebugResetOnboardingFailed =
      'settings.debug_reset_onboarding_failed';
  static const settingsDebugRefreshDeviceId =
      'settings.debug_refresh_device_id';
  static const settingsDebugRefreshDeviceIdDescription =
      'settings.debug_refresh_device_id_description';
  static const settingsDebugRefreshDeviceIdButton =
      'settings.debug_refresh_device_id_button';
  static const settingsDebugRefreshDeviceIdRunning =
      'settings.debug_refresh_device_id_running';
  static const settingsDebugRefreshDeviceIdSuccess =
      'settings.debug_refresh_device_id_success';
  static const settingsDebugRefreshDeviceIdFailed =
      'settings.debug_refresh_device_id_failed';
  static const settingsDebugRepairSqliteSchema =
      'settings.debug_repair_sqlite_schema';
  static const settingsDebugRepairSqliteSchemaDescription =
      'settings.debug_repair_sqlite_schema_description';
  static const settingsDebugRepairSqliteSchemaButton =
      'settings.debug_repair_sqlite_schema_button';
  static const settingsDebugRepairSqliteSchemaRunning =
      'settings.debug_repair_sqlite_schema_running';
  static const settingsDebugRepairSqliteSchemaSuccess =
      'settings.debug_repair_sqlite_schema_success';
  static const settingsDebugRepairSqliteSchemaFailed =
      'settings.debug_repair_sqlite_schema_failed';
  static const settingsUsage = 'settings.usage';
  static const settingsUsageActivity = 'settings.usage_activity';
  static const settingsUsageApiCalls = 'settings.usage_api_calls';
  static const settingsUsageAvgPerDay = 'settings.usage_avg_per_day';
  static const settingsUsageCacheRead = 'settings.usage_cache_read';
  static const settingsUsageCacheWrite = 'settings.usage_cache_write';
  static const settingsUsageDailyTokenTitle =
      'settings.usage_daily_token_title';
  static const settingsUsageDescription = 'settings.usage_description';
  static const settingsUsageFailedToLoad = 'settings.usage_failed_to_load';
  static const settingsUsageFilterAllModels =
      'settings.usage_filter_all_models';
  static const settingsUsageFilterAllProviders =
      'settings.usage_filter_all_providers';
  static const settingsUsageFilterModel = 'settings.usage_filter_model';
  static const settingsUsageFilterProvider = 'settings.usage_filter_provider';
  static const settingsUsageFreeDailyLimit = 'settings.usage_free_daily_limit';
  static const settingsUsageInput = 'settings.usage_input';
  static const settingsUsageLast30Days = 'settings.usage_last_30_days';
  static const settingsUsageNoData = 'settings.usage_no_data';
  static const settingsUsageOutput = 'settings.usage_output';
  static const settingsUsageReasoning = 'settings.usage_reasoning';
  static const settingsUsageRequestsToday = 'settings.usage_requests_today';
  static const settingsUsageSectionTokens = 'settings.usage_section_tokens';
  static const settingsUsageThisMonth = 'settings.usage_this_month';
  static const settingsUsageToday = 'settings.usage_today';
  static const settingsUsageTokens = 'settings.usage_tokens';
  static const settingsUsageVsLastMonth = 'settings.usage_vs_last_month';
  static const settingsUsageVsLastMonthFlat =
      'settings.usage_vs_last_month_flat';
  static const settingsUsageVsLastMonthNoData =
      'settings.usage_vs_last_month_no_data';
  static const settingsUsageListTitle = 'settings.usage_list_title';
  static const settingsUsageListColumnTime = 'settings.usage_list_column_time';
  static const settingsUsageListColumnProvider =
      'settings.usage_list_column_provider';
  static const settingsUsageListColumnModel =
      'settings.usage_list_column_model';
  static const settingsUsageListColumnInput =
      'settings.usage_list_column_input';
  static const settingsUsageListColumnOutput =
      'settings.usage_list_column_output';
  static const settingsUsageListPageOf = 'settings.usage_list_page_of';
  static const settingsUsageListEmpty = 'settings.usage_list_empty';
  static const settingsUsageListPrev = 'settings.usage_list_prev';
  static const settingsUsageListNext = 'settings.usage_list_next';
  static const settingsUsageTabOverview = 'settings.usage_tab_overview';
  static const settingsUsageTabSessions = 'settings.usage_tab_sessions';
  static const settingsUsageFilterSource = 'settings.usage_filter_source';
  static const settingsUsageFilterAllSources =
      'settings.usage_filter_all_sources';
  static const settingsUsageSourceDistribution =
      'settings.usage_source_distribution';
  static const settingsUsageSourceDistributionPeriod =
      'settings.usage_source_distribution_period';
  static const settingsUsageChartByTokenType =
      'settings.usage_chart_by_token_type';
  static const settingsUsageChartByFeature = 'settings.usage_chart_by_feature';
  static const settingsUsageSourceChat = 'settings.usage_source_chat';
  static const settingsUsageSourceAssistant = 'settings.usage_source_assistant';
  static const settingsUsageSourceRoleplay = 'settings.usage_source_roleplay';
  static const settingsUsageSourceMonologue = 'settings.usage_source_monologue';
  static const settingsUsageSourceTheater = 'settings.usage_source_theater';
  static const settingsUsageSourceCouncil = 'settings.usage_source_council';
  static const settingsUsageSourceOther = 'settings.usage_source_other';
  static const settingsUsageSessionsSortConversationTime =
      'settings.usage_sessions_sort_conversation_time';
  static const settingsUsageSessionsSortUsage =
      'settings.usage_sessions_sort_usage';
  static const settingsUsageSessionColumnSession =
      'settings.usage_session_column_session';
  static const settingsUsageSessionColumnCaller =
      'settings.usage_session_column_caller';
  static const settingsUsageSessionColumnMode =
      'settings.usage_session_column_mode';
  static const settingsUsageSessionColumnTokens =
      'settings.usage_session_column_tokens';
  static const settingsUsageSessionColumnLastUsed =
      'settings.usage_session_column_last_used';
  static const settingsUsageSessionUsage = 'settings.usage_session_usage';
  static const settingsUsageContextWindow = 'settings.usage_context_window';
  static const settingsUsageComposition = 'settings.usage_composition';
  static const settingsUsageMainConversation =
      'settings.usage_main_conversation';
  static const settingsUsageSubagents = 'settings.usage_subagents';
  static const settingsUsageRequests = 'settings.usage_requests';
  static const settingsUsageRuns = 'settings.usage_runs';
  static const settingsUsageNoSessions = 'settings.usage_no_sessions';
  static const settingsUsageSessionNotFound =
      'settings.usage_session_not_found';
  static const settingsUsageOpenCurrentSession =
      'settings.usage_open_current_session';
  static const settingsValidationApiKeyRequired =
      'settings.validation.api_key_required';
  static const settingsValidationBaseUrlRequired =
      'settings.validation.base_url_required';
  static const settingsValidationModelsRequired =
      'settings.validation.models_required';
  static const settingsValidationSelectLanguage =
      'settings.validation.select_language';
  // Aliases — abbreviated names that point to the same JSON keys
  static const agentDescPlanner = agentDescriptionsPlanner;
  static const agentDescWriter = agentDescriptionsWriter;
  static const agentDescArtist = agentDescriptionsArtist;
  static const agentDescChronicler = agentDescriptionsChronicler;
  static const agentDescMonologueNarrator = agentDescriptionsMonologueNarrator;
  static const agentDescRoleplayMaster = agentDescriptionsRoleplayMaster;
  static const agentDescTheaterActor = agentDescriptionsTheaterActor;
  static const askUserTitle = aiAskUserTitle;
  static const askUserHint = aiAskUserHint;
  static const askUserRecommended = aiAskUserRecommended;
  static const askUserYourAnswer = aiAskUserYourAnswer;
  static const askUserCancelled = aiAskUserCancelled;
  static const askUserErrorSelectionRequired = aiAskUserErrorSelectionRequired;
  static const askUserStatusPending = aiAskUserStatusPending;
  static const askUserStatusAnswered = aiAskUserStatusAnswered;
  static const askUserStatusCancelled = aiAskUserStatusCancelled;
  static const askUserStatusError = aiAskUserStatusError;
  static const editorSubAgentUnsavedChanges = editorSubagentUnsavedChanges;
  static const historyResourceTitle = historyResourceHistoryTitle;
  static const historyResourceEmpty = historyResourceHistoryEmpty;
  static const libraryTagsLabel = libraryTags;
  static const subagentDefaultReviewName = subagentDefaultsReviewName;
  static const subagentDefaultReviewDescription =
      subagentDefaultsReviewDescription;
  static const subagentDefaultStylePolishName = subagentDefaultsStylePolishName;
  static const subagentDefaultStylePolishDescription =
      subagentDefaultsStylePolishDescription;

  // ── sidebar ────────────────────────────────────────
  static const sidebarDeleteChapterConfirm = 'sidebar.delete_chapter_confirm';
  static const sidebarDeleteDocumentConfirm = 'sidebar.delete_document_confirm';
  static const sidebarDeleteFolderConfirm = 'sidebar.delete_folder_confirm';
  static const sidebarDeleteVolumeConfirm = 'sidebar.delete_volume_confirm';
  static const sidebarDocumentNameHint = 'sidebar.document_name_hint';
  static const sidebarMoveToPosition = 'sidebar.move_to_position';
  static const sidebarCurrentPosition = 'sidebar.current_position';
  static const sidebarSortAscending = 'sidebar.sort_ascending';
  static const sidebarSortDescending = 'sidebar.sort_descending';
  static const sidebarEmptyHint = 'sidebar.empty_hint';
  static const sidebarUntitledDocument = 'sidebar.untitled_document';
  static const sidebarUntitledEntry = 'sidebar.untitled_entry';
  static const sidebarUntitledFolder = 'sidebar.untitled_folder';
  // ── subagent ────────────────────────────────────────
  static const subagentDefaultsReviewDescription =
      'subagent.defaults.review.description';
  static const subagentDefaultsReviewName = 'subagent.defaults.review.name';
  static const subagentDefaultsStylePolishDescription =
      'subagent.defaults.style_polish.description';
  static const subagentDefaultsStylePolishName =
      'subagent.defaults.style_polish.name';
  static const subagentDeleteConfirm = 'subagent.delete_confirm';
  static const subagentDescription = 'subagent.description';
  static const subagentDuplicateName = 'subagent.duplicate_name';
  static const subagentEmpty = 'subagent.empty';
  static const subagentDisabled = 'subagent.disabled';
  static const subagentEnabled = 'subagent.enabled';
  static const subagentGlobal = 'subagent.global';
  static const subagentMode = 'subagent.mode';
  static const subagentModeChat = 'subagent.mode_chat';
  static const subagentModeCouncil = 'subagent.mode_council';
  static const subagentModel = 'subagent.model';
  static const subagentModelNotSelected = 'subagent.model_not_selected';
  static const subagentName = 'subagent.name';
  static const subagentNameRequired = 'subagent.name_required';
  static const subagentNoModelsAvailable = 'subagent.no_models_available';
  static const subagentNovel = 'subagent.novel';
  static const subagentOverrideHint = 'subagent.override_hint';
  static const subagentPrompt = 'subagent.prompt';
  static const subagentPromptHint = 'subagent.prompt_hint';
  static const subagentPromptRequired = 'subagent.prompt_required';
  static const subagentSubtitle = 'subagent.subtitle';
  static const subagentTitle = 'subagent.title';
  static const subagentTools = 'subagent.tools';
  static const subagentUseCustomPrompt = 'subagent.use_custom_prompt';
  // ── theater ────────────────────────────────────────
  static const theaterAddRound = 'theater.add_round';
  static const theaterCharactersCountFmt = 'theater.characters_count_fmt';
  static const theaterDefaultTitle = 'theater.default_title';
  static const theaterMinCharactersHint = 'theater.min_characters_hint';
  static const theaterNew = 'theater.new';
  static const theaterNoCharacters = 'theater.no_characters';
  static const theaterPerforming = 'theater.performing';
  static const theaterRounds = 'theater.rounds';
  static const theaterSceneDescription = 'theater.scene_description';
  static const theaterSceneHint = 'theater.scene_hint';
  static const theaterSelectCharacters = 'theater.select_characters';
  static const theaterSessionTitleFmt = 'theater.session_title_fmt';
  static const theaterSpeakingFmt = 'theater.speaking_fmt';
  static const theaterStart = 'theater.start';
  static const theaterTurn = 'theater.turn';
  static const theaterDirectionHint = 'theater.direction_hint';
  static const theaterDirectionLabel = 'theater.direction_label';
  static const theaterDirectionInsert = 'theater.direction_insert';
  static const theaterDirectionRemove = 'theater.direction_remove';
  static const theaterSpeakFmt = 'theater.speak_fmt';
  static const theaterLineRegenerate = 'theater.line_regenerate';
  static const theaterWriteProseThird = 'theater.write_prose_third';
  static const theaterWriteProsePovFmt = 'theater.write_prose_pov_fmt';
  static const theaterWriteTranscriptOnly = 'theater.write_transcript_only';
  // ── todo ────────────────────────────────────────
  static const todoPanelTitle = 'todo.panel_title';
  static const todoToolCardTitle = 'todo.tool_card_title';
  static const todoRemaining = 'todo.remaining';
  // ── workspace ────────────────────────────────────────
  static const workspaceAddChapter = 'workspace.add_chapter';
  static const workspaceAddChapterOrVolume = 'workspace.add_chapter_or_volume';
  static const workspaceAddDocumentOrFolder =
      'workspace.add_document_or_folder';
  static const workspaceCreateFolderFailed = 'workspace.create_folder_failed';
  static const workspaceAutoSaveEnabled = 'workspace.auto_save_enabled';
  static const workspaceAutoSaveSucceeded = 'workspace.auto_save_succeeded';
  static const workspaceAutomations = 'workspace.automations';
  static const workspaceBackToLibrary = 'workspace.back_to_library';
  static const workspaceAgentConfig = 'workspace.agent_config';
  static const workspaceAiQuickContinue = 'workspace.ai_quick_continue';
  static const workspaceAiQuickPlot = 'workspace.ai_quick_plot';
  static const workspaceAiQuickSetting = 'workspace.ai_quick_setting';
  static const workspaceAskAiPlaceholder = 'workspace.ask_ai_placeholder';
  static const workspaceBrowseSettings = 'workspace.browse_settings';
  static const workspaceCanvas = 'workspace.canvas';
  static const workspaceChangesSummary = 'workspace.changes_summary';
  static const workspaceChapterAutoFormat = 'workspace.chapter_auto_format';
  static const workspaceChapterFormatAll = 'workspace.chapter_format_all';
  static const workspaceChapterFormatScopeCurrent =
      'workspace.chapter_format_scope_current';
  static const workspaceChapterFormatConfirmTitle =
      'workspace.chapter_format_confirm_title';
  static const workspaceChapterFormatConfirmMessage =
      'workspace.chapter_format_confirm_message';
  static const workspaceChapterFormatDone = 'workspace.chapter_format_done';
  static const workspaceChapterFormatProgressLabel =
      'workspace.chapter_format_progress_label';
  static const workspaceChapterFormatFailed = 'workspace.chapter_format_failed';
  static const workspaceChapterBodyHint = 'workspace.chapter_body_hint';
  static const workspaceChapterCopy = 'workspace.chapter_copy';
  static const workspaceChapterCopyAddRule = 'workspace.chapter_copy_add_rule';
  static const workspaceChapterCopyFrom = 'workspace.chapter_copy_from';
  static const workspaceChapterCopyReplaceTitle =
      'workspace.chapter_copy_replace_title';
  static const workspaceChapterCopyReplaceAction =
      'workspace.chapter_copy_replace_action';
  static const workspaceChapterCopyRules = 'workspace.chapter_copy_rules';
  static const workspaceChapterCopyTo = 'workspace.chapter_copy_to';
  static const workspaceChapterReplace = 'workspace.chapter_replace';
  static const workspaceChapterOutline = 'workspace.chapter_outline';
  static const workspaceChapterEvents = 'workspace.chapter_events';
  static const workspaceChapterEventStateChange =
      'workspace.chapter_event_state_change';
  static const workspaceChapterTension = 'workspace.chapter_tension';
  static const workspaceOpenOutlineWindow = 'workspace.open_outline_window';
  static const workspaceOutlineWindowConnectionFailed =
      'workspace.outline_window_connection_failed';
  static const workspaceChapterTitle = 'workspace.chapter_title';
  static const workspaceChapters = 'workspace.chapters';
  static const workspaceChaptersHint = 'workspace.chapters_hint';
  static const workspaceRedo = 'workspace.redo';
  static const workspaceUndo = 'workspace.undo';
  static const workspaceCjkCharacters = 'workspace.cjk_characters';
  static const workspaceCharacterAddPhoto = 'workspace.character_add_photo';
  static const workspaceCharacterAvatar = 'workspace.character_avatar';
  static const workspaceCharacterIdentityHint =
      'workspace.character_identity_hint';
  static const workspaceCharacterAgeHint = 'workspace.character_age_hint';
  static const workspaceCharacterMotivationHint =
      'workspace.character_motivation_hint';
  static const workspaceCharacterArcHint = 'workspace.character_arc_hint';
  static const workspaceCharacterDescriptionHint =
      'workspace.character_description_hint';
  static const workspaceCharacterAppearanceHint =
      'workspace.character_appearance_hint';
  static const workspaceCharacterAppearanceLabel =
      'workspace.character_appearance_label';
  static const workspaceCharacterDescriptionLabel =
      'workspace.character_description_label';
  static const workspaceCharacterSectionIdentity =
      'workspace.character_section_identity';
  static const workspaceCharacterSectionIdentityHint =
      'workspace.character_section_identity_hint';
  static const workspaceCharacterSectionFigure =
      'workspace.character_section_figure';
  static const workspaceCharacterSectionFigureHint =
      'workspace.character_section_figure_hint';
  static const workspaceCharacterSectionBiography =
      'workspace.character_section_biography';
  static const workspaceCharacterSectionBiographyHint =
      'workspace.character_section_biography_hint';
  static const workspaceCharacterSectionOutward =
      'workspace.character_section_outward';
  static const workspaceCharacterSectionOutwardHint =
      'workspace.character_section_outward_hint';
  static const workspaceCharacterSectionPsyche =
      'workspace.character_section_psyche';
  static const workspaceCharacterSectionPsycheHint =
      'workspace.character_section_psyche_hint';
  static const workspaceCharacterSectionStory =
      'workspace.character_section_story';
  static const workspaceCharacterSectionStoryHint =
      'workspace.character_section_story_hint';
  static const workspaceCharacterSectionRelations =
      'workspace.character_section_relations';
  static const workspaceCharacterSectionRelationsHint =
      'workspace.character_section_relations_hint';
  static const workspaceCharacterRelationsCharacters =
      'workspace.character_relations_characters';
  static const workspaceCharacterRelationsFactions =
      'workspace.character_relations_factions';
  static const workspaceCharacterRelationsItems =
      'workspace.character_relations_items';
  static const workspaceCharacterRelationsOpenGraph =
      'workspace.character_relations_open_graph';
  static const workspaceCharacterRelationsMore =
      'workspace.character_relations_more';
  static const workspaceCharacterRelationsCollapse =
      'workspace.character_relations_collapse';
  static const workspaceCharacterRelationsEmpty =
      'workspace.character_relations_empty';
  static const workspaceCharacterPhotosLabel =
      'workspace.character_photos_label';
  static const workspaceCharacterAiGenerate = 'workspace.character_ai_generate';
  static const workspaceCharacterAliasesLabel =
      'workspace.character_aliases_label';
  static const workspaceCharacterAliasesHint =
      'workspace.character_aliases_hint';
  static const workspaceCharacterAliasesAdd = 'workspace.character_aliases_add';
  static const workspaceCharacterAliasInvalid =
      'workspace.character_alias_invalid';
  static const workspaceCharacterTagsLabel = 'workspace.character_tags_label';
  static const workspaceCharacterTagsHint = 'workspace.character_tags_hint';
  static const workspaceCharacterTagsAdd = 'workspace.character_tags_add';
  static const workspaceCharacterNameConflictsWithAlias =
      'workspace.character_name_conflicts_with_alias';
  static const workspaceCharacterPersonalityLabel =
      'workspace.character_personality_label';
  static const workspaceCharacterPersonalityHint =
      'workspace.character_personality_hint';
  static const workspaceCharacterBehaviorTagsLabel =
      'workspace.character_behavior_tags_label';
  static const workspaceCharacterBehaviorTagsHint =
      'workspace.character_behavior_tags_hint';
  static const workspaceCharacterBehaviorTagAdd =
      'workspace.character_behavior_tag_add';
  static const workspaceCharacterBehaviorTagNameHint =
      'workspace.character_behavior_tag_name_hint';
  static const workspaceCharacterBehaviorTagContextHint =
      'workspace.character_behavior_tag_context_hint';
  static const workspaceCharacterBehaviorTagContextRequired =
      'workspace.character_behavior_tag_context_required';
  static const workspaceCharacterBehaviorTagDuplicate =
      'workspace.character_behavior_tag_duplicate';
  static const workspaceCharacterBehaviorTagRemove =
      'workspace.character_behavior_tag_remove';
  static const workspaceCharacterCurrentStateLabel =
      'workspace.character_current_state_label';
  static const workspaceCharacterCurrentStateHint =
      'workspace.character_current_state_hint';
  static const workspaceCharacterGenderHint = 'workspace.character_gender_hint';
  static const workspaceCharacterGenerateAvatar =
      'workspace.character_generate_avatar';
  static const workspaceCharacterGeneratePhoto =
      'workspace.character_generate_photo';
  static const workspaceCharacterNameHint = 'workspace.character_name_hint';
  static const workspaceCharacterPhotos = 'workspace.character_photos';
  static const workspaceCharacterPickAvatar = 'workspace.character_pick_avatar';
  static const workspaceCharacterPickPhoto = 'workspace.character_pick_photo';
  static const workspaceCharacterRemovePhoto =
      'workspace.character_remove_photo';
  static const workspaceCharacterRoleHint = 'workspace.character_role_hint';
  static const workspaceCharacterSetAsAvatar =
      'workspace.character_set_as_avatar';
  static const workspaceCharacterSetAvatarFirst =
      'workspace.character_set_avatar_first';
  static const workspaceCharacterSkillDialogClose =
      'workspace.character_skill_dialog_close';
  static const workspaceCharacterSkillDialogContent =
      'workspace.character_skill_dialog_content';
  static const workspaceCharacterSkillDialogContentEmpty =
      'workspace.character_skill_dialog_content_empty';
  static const workspaceCharacterSkillDialogTitle =
      'workspace.character_skill_dialog_title';
  static const workspaceCharacterSkills = 'workspace.character_skills';
  static const workspaceCharacterSkillsAdd = 'workspace.character_skills_add';
  static const workspaceCharacterSkillsAddDialogTitle =
      'workspace.character_skills_add_dialog_title';
  static const workspaceCharacterSkillsAddModeLink =
      'workspace.character_skills_add_mode_link';
  static const workspaceCharacterSkillsAddModeCreate =
      'workspace.character_skills_add_mode_create';
  static const workspaceCharacterSkillsAddTitleLabel =
      'workspace.character_skills_add_title_label';
  static const workspaceCharacterSkillsAddTitleHint =
      'workspace.character_skills_add_title_hint';
  static const workspaceCharacterSkillsAddContentLabel =
      'workspace.character_skills_add_content_label';
  static const workspaceCharacterSkillsAddContentHint =
      'workspace.character_skills_add_content_hint';
  static const workspaceCharacterSkillsAddRelationLabel =
      'workspace.character_skills_add_relation_label';
  static const workspaceCharacterSkillsAddErrorTitle =
      'workspace.character_skills_add_error_title';
  static const workspaceCharacterSkillsAddErrorSelectSkill =
      'workspace.character_skills_add_error_select_skill';
  static const workspaceCharacterSkillsEmpty =
      'workspace.character_skills_empty';
  static const workspaceCharacterSkillsEmptyHint =
      'workspace.character_skills_empty_hint';
  static const workspaceCharacterSkillsRemove =
      'workspace.character_skills_remove';
  static const workspaceCharacterSummaryHint =
      'workspace.character_summary_hint';
  static const workspaceCharacterSummaryLabel =
      'workspace.character_summary_label';
  static const workspaceCharacters = 'workspace.characters';
  static const workspaceCharactersHint = 'workspace.characters_hint';
  static const workspaceCharacterFirstAppearChapter =
      'workspace.character_first_appear_chapter';
  static const workspaceForeshadowOpenPosition =
      'workspace.foreshadow_open_position';
  static const workspaceForeshadowSetupPosition =
      'workspace.foreshadow_setup_position';
  static const workspaceForeshadowPayoffPosition =
      'workspace.foreshadow_payoff_position';
  static const workspaceForeshadowPositionUnavailable =
      'workspace.foreshadow_position_unavailable';
  static const workspaceForeshadowPayoffPending =
      'workspace.foreshadow_payoff_pending';
  static const workspaceNavigateToChapter = 'workspace.navigate_to_chapter';
  static const workspaceUntitledChapter = 'workspace.untitled_chapter';
  static const workspaceChatPlaceholder = 'workspace.chat_placeholder';
  static const workspaceChats = 'workspace.chats';
  static const workspaceCollectionEmpty = 'workspace.collection_empty';
  static const workspaceContents = 'workspace.contents';
  static const workspaceContinueChapter = 'workspace.continue_chapter';
  static const workspaceContinueWriting = 'workspace.continue_writing';
  static const workspaceContinueWritingHint = 'workspace.continue_writing_hint';
  static const workspaceCreateFirstChapter = 'workspace.create_first_chapter';
  static const workspaceCreateFirstEntry = 'workspace.create_first_entry';
  static const workspaceCreateFirstMap = 'workspace.create_first_map';
  static const workspaceCreateDraftUnsavedMessage =
      'workspace.create_draft_unsaved_message';
  static const workspaceCreateDraftUnsavedTitle =
      'workspace.create_draft_unsaved_title';
  static const workspaceCreativeSnippets = 'workspace.creative_snippets';
  static const workspaceCreativeSnippetsEmpty =
      'workspace.creative_snippets_empty';
  static const workspaceCreativeSnippetsViewMore =
      'workspace.creative_snippets_view_more';
  static const workspaceCreatures = 'workspace.creatures';
  static const workspaceCreaturesHint = 'workspace.creatures_hint';
  static const workspaceDatabasePathLoadFailed =
      'workspace.database_path_load_failed';
  static const workspaceEntityGraph = 'workspace.entityGraph';
  static const workspaceEntryCategoryHint = 'workspace.entry_category_hint';
  static const workspaceEntryCategoryLabel = 'workspace.entry_category_label';
  static const workspaceEntryCategoryLoreHint =
      'workspace.entry_category_lore_hint';
  static const workspaceEntryCategoryMaterialsHint =
      'workspace.entry_category_materials_hint';
  static const workspaceEntryCategorySkillsHint =
      'workspace.entry_category_skills_hint';
  static const workspaceEntryCategoryItemsHint =
      'workspace.entry_category_items_hint';
  static const workspaceEntryCategoryFactionsHint =
      'workspace.entry_category_factions_hint';
  static const workspaceEntryCategoryCreaturesHint =
      'workspace.entry_category_creatures_hint';
  static const workspaceEntryContentHint = 'workspace.entry_content_hint';
  static const workspaceEntryTitleHint = 'workspace.entry_title_hint';
  static const workspaceExtra = 'workspace.extra';
  static const workspaceFactions = 'workspace.factions';
  static const workspaceFactionsHint = 'workspace.factions_hint';
  static const workspaceFavorite = 'workspace.favorite';
  static const workspaceFilesChanged = 'workspace.files_changed';
  static const workspaceFolder = 'workspace.folder';
  static const workspaceFolderCreateHint = 'workspace.folder_create_hint';
  static const workspaceForeshadowPayoffHint =
      'workspace.foreshadow_payoff_hint';
  static const workspaceForeshadowSetupHint = 'workspace.foreshadow_setup_hint';
  static const workspaceForeshadowings = 'workspace.foreshadowings';
  static const workspaceForeshadowingsHint = 'workspace.foreshadowings_hint';
  static const workspaceRelations = 'workspace.relations';
  static const foreshadowingStatusPending =
      'workspace.foreshadowing_status_pending';
  static const foreshadowingStatusPlanted =
      'workspace.foreshadowing_status_planted';
  static const foreshadowingStatusPayoff =
      'workspace.foreshadowing_status_payoff';
  static const foreshadowingStatusAbandoned =
      'workspace.foreshadowing_status_abandoned';
  static const workspaceIndexRebuildRequiredTitle =
      'workspace.index_rebuild_required_title';
  static const workspaceItems = 'workspace.items';
  static const workspaceItemsHint = 'workspace.items_hint';
  static const workspaceItemGeneratePhoto = 'workspace.item_generate_photo';
  static const workspaceItemPhotos = 'workspace.item_photos';
  static const workspaceItemPickPhoto = 'workspace.item_pick_photo';
  static const workspaceItemRemovePhoto = 'workspace.item_remove_photo';
  static const workspaceJumpToEnd = 'workspace.jump_to_end';
  static const workspaceJumpToStart = 'workspace.jump_to_start';
  static const workspaceLabel = 'workspace.label';
  static const workspaceLastWroteEmpty = 'workspace.last_wrote_empty';
  static const workspaceLastWroteFromChapter =
      'workspace.last_wrote_from_chapter';
  static const workspaceLastWroteText = 'workspace.last_wrote_text';
  static const workspaceMapCanvasSize = 'workspace.map_canvas_size';
  static const workspaceMapDescriptionHint = 'workspace.map_description_hint';
  static const workspaceMapHeight = 'workspace.map_height';
  static const workspaceMapNameHint = 'workspace.map_name_hint';
  static const workspaceMapNotFound = 'workspace.map_not_found';
  static const workspaceMapSaved = 'workspace.map_saved';
  static const workspaceMapWidth = 'workspace.map_width';
  static const workspaceMaps = 'workspace.maps';
  static const workspaceMapsHint = 'workspace.maps_hint';
  static const workspaceMarkdown = 'workspace.markdown';
  static const workspaceMaterials = 'workspace.materials';
  static const workspaceMaterialsHint = 'workspace.materials_hint';
  static const workspaceMoreEntrances = 'workspace.more_entrances';
  static const workspaceNewChapter = 'workspace.new_chapter';
  static const workspaceNewChapterInVolume = 'workspace.new_chapter_in_volume';
  static const workspaceNewCharacter = 'workspace.new_character';
  static const workspaceNewVolume = 'workspace.new_volume';
  static const workspaceNewVolumeHint = 'workspace.new_volume_hint';
  static const workspaceRenameVolume = 'workspace.rename_volume';
  static const workspaceVolume = 'workspace.volume';
  static const workspaceVolumeNumber = 'workspace.volume_number';
  static const workspaceNewCreature = 'workspace.new_creature';
  static const workspaceNewDocument = 'workspace.new_document';
  static const workspaceNewEntry = 'workspace.new_entry';
  static const workspaceNewFaction = 'workspace.new_faction';
  static const workspaceImportFile = 'workspace.import_file';
  static const workspaceChooseFile = 'workspace.choose_file';
  static const workspaceChooseDirectory = 'workspace.choose_directory';
  static const workspaceImportFolder = 'workspace.import_folder';
  static const workspaceImportMaterial = 'workspace.import_material';
  static const workspaceImportWorldbuilding = 'workspace.import_worldbuilding';
  static const workspaceImportFailed = 'workspace.import_failed';
  static const workspaceImportEmpty = 'workspace.import_empty';
  static const workspaceImportResult = 'workspace.import_result';
  static const workspaceImportResultWithSkipped =
      'workspace.import_result_with_skipped';
  static const workspaceNewFolder = 'workspace.new_folder';
  static const workspaceNewFolderHint = 'workspace.new_folder_hint';
  static const workspaceNewForeshadowing = 'workspace.new_foreshadowing';
  static const workspaceNewItem = 'workspace.new_item';
  static const workspaceNewMap = 'workspace.new_map';
  static const workspaceNewMaterial = 'workspace.new_material';
  static const workspaceNewOutline = 'workspace.new_outline';
  static const workspaceNewSkill = 'workspace.new_skill';
  static const workspaceNewWorldbuilding = 'workspace.new_worldbuilding';
  static const workspaceNoChapterSelected = 'workspace.no_chapter_selected';
  static const workspaceNoEntrySelected = 'workspace.no_entry_selected';
  static const workspaceNoMaps = 'workspace.no_maps';
  static const workspaceNoPendingChanges = 'workspace.no_pending_changes';
  static const workspaceNovelDescription = 'workspace.novel_description';
  static const workspaceNovelOverview = 'workspace.novel_overview';
  static const workspaceOutlineAddBeat = 'workspace.outline_add_beat';
  static const workspaceOutlineArchitectureChapters =
      'workspace.outline_architecture_chapters';
  static const workspaceOutlineArchitectureHint =
      'workspace.outline_architecture_hint';
  static const workspaceOutlineArchitectureTitle =
      'workspace.outline_architecture_title';
  static const workspaceOutlineArchitectureTotal =
      'workspace.outline_architecture_total';
  static const workspaceOutlineGlobal = 'workspace.outline_global';
  static const workspaceViewGlobalOutlines = 'workspace.view_global_outlines';
  static const workspaceOutlineGlobalEmptyHint =
      'workspace.outline_global_empty_hint';
  static const workspaceOutlineGlobalHint = 'workspace.outline_global_hint';
  static const workspaceOutlineGlobalTitle = 'workspace.outline_global_title';
  static const workspaceOutlineBeatChapterCountDecrease =
      'workspace.outline_beat_chapter_count_decrease';
  static const workspaceOutlineBeatChapterCountIncrease =
      'workspace.outline_beat_chapter_count_increase';
  static const workspaceOutlineBeatChapterCountLabel =
      'workspace.outline_beat_chapter_count_label';
  static const workspaceOutlineBeatChapterCountMin =
      'workspace.outline_beat_chapter_count_min';
  static const workspaceOutlineBeatChapterCountValue =
      'workspace.outline_beat_chapter_count_value';
  static const workspaceOutlineBeatChapterLabel =
      'workspace.outline_beat_chapter_label';
  static const workspaceOutlineBeatConflictLabel =
      'workspace.outline_beat_conflict_label';
  static const workspaceOutlineBeatContentHint =
      'workspace.outline_beat_content_hint';
  static const workspaceOutlineBeatDragHandle =
      'workspace.outline_beat_drag_handle';
  static const workspaceOutlineBeatSequenceLabel =
      'workspace.outline_beat_sequence_label';
  static const workspaceOutlineBeatChapterRange =
      'workspace.outline_beat_chapter_range';
  static const workspaceOutlineTimelineExpand =
      'workspace.outline_timeline_expand';
  static const workspaceOutlineTimelineCollapse =
      'workspace.outline_timeline_collapse';
  static const workspaceOutlineTimelineShow = 'workspace.outline_timeline_show';
  static const workspaceOutlineTimelineHide = 'workspace.outline_timeline_hide';
  static const workspaceOutlineBeatTitleHint =
      'workspace.outline_beat_title_hint';
  static const workspaceOutlineBeatCardPreviewLabel =
      'workspace.outline_beat_card_preview_label';
  static const workspaceOutlineBeatInsertTemplate =
      'workspace.outline_beat_insert_template';
  static const workspaceOutlineBeatContentTemplate =
      'workspace.outline_beat_content_template';
  static const workspaceOutlineBeatGoalLabel =
      'workspace.outline_beat_goal_label';
  static const workspaceOutlineBeatOutcomeLabel =
      'workspace.outline_beat_outcome_label';
  static const workspaceOutlineBeatTimeLabel =
      'workspace.outline_beat_time_label';
  static const workspaceOutlineConflictHint = 'workspace.outline_conflict_hint';
  static const workspaceOutlineConflictLabel =
      'workspace.outline_conflict_label';
  static const workspaceOutlineContentHint = 'workspace.outline_content_hint';
  static const workspaceOutlineEditorEmptyHint =
      'workspace.outline_editor_empty_hint';
  static const workspaceOutlineEndingHint = 'workspace.outline_ending_hint';
  static const workspaceOutlineEndingLabel = 'workspace.outline_ending_label';
  static const workspaceOutlineGoalHint = 'workspace.outline_goal_hint';
  static const workspaceOutlineGoalLabel = 'workspace.outline_goal_label';
  static const workspaceOutlineGuideCausality =
      'workspace.outline_guide_causality';
  static const workspaceOutlineGuideEscalation =
      'workspace.outline_guide_escalation';
  static const workspaceOutlineGuidePremise = 'workspace.outline_guide_premise';
  static const workspaceOutlineNotesHint = 'workspace.outline_notes_hint';
  static const workspaceOutlineNotesLabel = 'workspace.outline_notes_label';
  static const workspaceOutlineOverviewTitle =
      'workspace.outline_overview_title';
  static const workspaceOutlinePremiseHint = 'workspace.outline_premise_hint';
  static const workspaceOutlinePremiseLabel = 'workspace.outline_premise_label';
  static const workspaceOutlineStakesHint = 'workspace.outline_stakes_hint';
  static const workspaceOutlineStakesLabel = 'workspace.outline_stakes_label';
  static const workspaceOutlineStatusFinished =
      'workspace.outline_status_finished';
  static const workspaceOutlineStatusInProgress =
      'workspace.outline_status_in_progress';
  static const workspaceOutlineStatusPending =
      'workspace.outline_status_pending';
  static const workspaceOutlineStartChapter = 'workspace.outline_start_chapter';
  static const workspaceOutlineTimelineEmptyHint =
      'workspace.outline_timeline_empty_hint';
  static const workspaceOutlineTimelineEmptyTitle =
      'workspace.outline_timeline_empty_title';
  static const workspaceOutlineTimelineTitle =
      'workspace.outline_timeline_title';
  static const workspaceOutlineUntitledBeat = 'workspace.outline_untitled_beat';
  static const workspaceOutlines = 'workspace.outlines';
  static const workspaceOutlinesHint = 'workspace.outlines_hint';
  static const workspaceOverview = 'workspace.overview';
  static const workspacePendingChangesTitle = 'workspace.pending_changes_title';
  static const workspacePreview = 'workspace.preview';
  static const workspacePreviewDescription = 'workspace.preview_description';
  static const workspacePreviewDevicePhoneSmall =
      'workspace.preview_device_phone_small';
  static const workspacePreviewDevicePhone = 'workspace.preview_device_phone';
  static const workspacePreviewDevicePhoneLarge =
      'workspace.preview_device_phone_large';
  static const workspacePreviewDeviceTablet = 'workspace.preview_device_tablet';
  static const workspacePreviewStats = 'workspace.preview_stats';
  static const workspaceProjectIntro = 'workspace.project_intro';
  static const workspaceCoverPreview = 'workspace.cover_preview';
  static const workspaceCoverSaveLocal = 'workspace.cover_save_local';
  static const workspaceCoverSaveSuccess = 'workspace.cover_save_success';
  static const workspaceCoverSaveFailed = 'workspace.cover_save_failed';
  static const workspaceReadingTime = 'workspace.reading_time';
  static const workspaceRebuildChapterIndexes =
      'workspace.rebuild_chapter_indexes';
  static const workspaceRebuildConfigDisabled =
      'workspace.rebuild_config_disabled';
  static const workspaceRebuildConfigMissing =
      'workspace.rebuild_config_missing';
  static const workspaceRebuildConfigModelNotSupported =
      'workspace.rebuild_config_model_not_supported';
  static const workspaceRebuildConfigNoApiKey =
      'workspace.rebuild_config_no_api_key';
  static const workspaceRebuildConfigNoBaseUrl =
      'workspace.rebuild_config_no_base_url';
  static const workspaceRebuildConfigNoModels =
      'workspace.rebuild_config_no_models';
  static const workspaceRebuildErrors = 'workspace.rebuild_errors';
  static const workspaceRebuildFailed = 'workspace.rebuild_failed';
  static const workspaceRebuildPause = 'workspace.rebuild_pause';
  static const workspaceRebuildProgress = 'workspace.rebuild_progress';
  static const workspaceRebuildResume = 'workspace.rebuild_resume';
  static const workspaceRebuildStarted = 'workspace.rebuild_started';
  static const workspaceRollbackChange = 'workspace.rollback_change';
  static const workspaceRollbackAllChanges = 'workspace.rollback_all_changes';
  static const workspaceRollbackAllConfirmMessage =
      'workspace.rollback_all_confirm_message';
  static const workspaceRollbackAllConfirmTitle =
      'workspace.rollback_all_confirm_title';
  static const workspaceRollbackDone = 'workspace.rollback_done';
  static const workspaceAcceptChangesFailed = 'workspace.accept_changes_failed';
  static const workspaceRecentChanges = 'workspace.recent_changes';
  static const workspaceRenameFolder = 'workspace.rename_folder';
  static const workspaceSaveChapter = 'workspace.save_chapter';
  static const workspaceSaveEntry = 'workspace.save_entry';
  static const workspaceSearch = 'workspace.search';
  static const workspaceSearchEmpty = 'workspace.search_empty';
  static const workspaceSearchHint = 'workspace.search_hint';
  static const workspaceSearchIdle = 'workspace.search_idle';
  static const workspaceSearchInputLabel = 'workspace.search_input_label';
  static const workspaceSearchLoading = 'workspace.search_loading';
  static const workspaceSearchResults = 'workspace.search_results';
  static const workspaceSearchResultsCount = 'workspace.search_results_count';
  static const workspaceSearchScopeTitle = 'workspace.search_scope_title';
  static const workspaceSearchScopeTooltip = 'workspace.search_scope_tooltip';
  static const workspaceSearchTitle = 'workspace.search_title';
  static const workspaceChapterPickerEmpty = 'workspace.chapter_picker_empty';
  static const workspaceSearchChapters = 'workspace.search_chapters';
  static const workspaceSelectChapter = 'workspace.select_chapter';
  static const workspaceSectionHeader = 'workspace.section_header';
  static const workspaceSelectChapterToWrite =
      'workspace.select_chapter_to_write';
  static const workspaceSelectEntryToEdit = 'workspace.select_entry_to_edit';
  static const workspaceSkills = 'workspace.skills';
  static const workspaceSkillsHint = 'workspace.skills_hint';
  static const workspaceSnippetTagInspiration =
      'workspace.snippet_tag_inspiration';
  static const workspaceSnippetTagRelation = 'workspace.snippet_tag_relation';
  static const workspaceSnippetTagSetting = 'workspace.snippet_tag_setting';
  static const workspaceSplit = 'workspace.split';
  static const workspaceStartFirstChapter = 'workspace.start_first_chapter';
  static const workspaceStatChapters = 'workspace.stat_chapters';
  static const workspaceStatCharacters = 'workspace.stat_characters';
  static const workspaceStatForeshadowings = 'workspace.stat_foreshadowings';
  static const workspaceStatNotes = 'workspace.stat_notes';
  static const workspaceStatSettings = 'workspace.stat_settings';
  static const workspaceStatWorldbuilding = 'workspace.stat_worldbuilding';
  static const workspaceStatusWithChapter = 'workspace.status_with_chapter';
  static const workspaceArabicDigits = 'workspace.arabic_digits';
  static const workspaceIndents = 'workspace.indents';
  static const workspaceLatinWords = 'workspace.latin_words';
  static const workspaceParagraphs = 'workspace.paragraphs';
  static const workspacePunctuation = 'workspace.punctuation';
  static const workspaceTextCharacters = 'workspace.text_characters';
  static const workspaceUntitledFolder = 'workspace.untitled_folder';
  static const workspaceViewChanges = 'workspace.view_changes';
  static const workspaceViewOutline = 'workspace.view_outline';
  static const workspaceWhitespace = 'workspace.whitespace';
  static const workspaceWordCount = 'workspace.word_count';
  static const workspaceWordCountDetails = 'workspace.word_count_details';
  static const workspaceWordCountDetailsHint =
      'workspace.word_count_details_hint';
  static const workspaceWordUnits = 'workspace.word_units';
  static const workspaceLore = 'workspace.lore';
  static const workspaceLoreHint = 'workspace.lore_hint';
  static const workspaceWorlds = 'workspace.worlds';
  static const workspaceWrite = 'workspace.write';
  static const workspaceWritingCharacters = 'workspace.writing_characters';
  static const workspaceWritingCharactersHint =
      'workspace.writing_characters_hint';
  static const workspaceWritingEntrances = 'workspace.writing_entrances';
  static const workspaceWritingMain = 'workspace.writing_main';
  static const workspaceWritingMainHint = 'workspace.writing_main_hint';
  static const workspaceWritingOutlinePlot = 'workspace.writing_outline_plot';
  static const workspaceWritingOutlinePlotHint =
      'workspace.writing_outline_plot_hint';
  static const workspaceSidebarGroupSystem = 'workspace.sidebar_group_system';
  static const workspaceSidebarGroupWriting = 'workspace.sidebar_group_writing';
  static const workspaceSidebarGroupWorld = 'workspace.sidebar_group_world';
  static const workspaceSidebarGroupAi = 'workspace.sidebar_group_ai';
  static const workspaceSidebarGroupInspiration =
      'workspace.sidebar_group_inspiration';
  static const workspaceSidebarCompendium = 'workspace.sidebar_compendium';
  static const workspaceCompendiumNoSelection =
      'workspace.compendium_no_selection';
  static const workspaceCompendiumSelectToEdit =
      'workspace.compendium_select_to_edit';
  static const workspaceCompendiumCreateFirst =
      'workspace.compendium_create_first';
  static const workspaceNewCompendiumEntry = 'workspace.new_compendium_entry';
  static const workspaceSidebarEntityGraph = 'workspace.sidebar_entity_graph';
  static const workspaceStoryProgress = 'workspace.story_progress';
  static const workspaceStoryProgressEmpty = 'workspace.story_progress_empty';
  static const workspaceStoryProgressEmptyHint =
      'workspace.story_progress_empty_hint';
  static const workspaceStoryProgressTensionCurve =
      'workspace.story_progress_tension_curve';
  static const workspaceStoryProgressNoTension =
      'workspace.story_progress_no_tension';
  static const workspaceStoryProgressTensionIntervalAuto =
      'workspace.story_progress_tension_interval_auto';
  static const workspaceStoryProgressTensionIntervalPerChapter =
      'workspace.story_progress_tension_interval_per_chapter';
  static const workspaceStoryProgressTensionIntervalChapters =
      'workspace.story_progress_tension_interval_chapters';
  static const workspaceStoryProgressTensionAveraged =
      'workspace.story_progress_tension_averaged';
  static const workspaceStoryProgressEdit = 'workspace.story_progress_edit';
  static const workspaceStoryProgressEditHint =
      'workspace.story_progress_edit_hint';
  static const workspaceSidebarOutline = 'workspace.sidebar_outline';
  static const workspaceSidebarForeshadowing =
      'workspace.sidebar_foreshadowing';
  static const workspaceSidebarMap = 'workspace.sidebar_map';
  static const workspaceSidebarAssets = 'workspace.sidebar_assets';

  static const screenplaySceneShortTitle = 'screenplay.scene_short_title';
  static const screenplaySceneShortTitleHint =
      'screenplay.scene_short_title_hint';
  static const screenplaySceneEmotion = 'screenplay.scene_emotion';
  static const screenplaySceneEmotionAdd = 'screenplay.scene_emotion_add';
  static const screenplaySceneEvents = 'screenplay.scene_events';
  static const screenplaySceneEventAdd = 'screenplay.scene_event_add';
  static const screenplaySceneEventTitle = 'screenplay.scene_event_title';
  static const screenplaySceneEventSummary = 'screenplay.scene_event_summary';
  static const screenplaySceneEventNumber = 'screenplay.scene_event_number';
  static const screenplaySceneStateChange = 'screenplay.scene_state_change';
  static const screenplaySceneEventsHint = 'screenplay.scene_events_hint';
  static const screenplaySceneEventsEmpty = 'screenplay.scene_events_empty';
  static const screenplaySceneProperties = 'screenplay.scene_properties';
  static const screenplaySceneAnalysisStale = 'screenplay.scene_analysis_stale';
  static const screenplaySceneAnalysisStaleHint =
      'screenplay.scene_analysis_stale_hint';
  static const screenplaySceneEventRequired = 'screenplay.scene_event_required';
  static const screenplayInteriorAndExterior =
      'screenplay.interior_and_exterior';
  static const screenplayUnspecified = 'screenplay.unspecified';

  // 独立导演工作区。
  static const directorCameraMoves = 'director.camera_moves';
  static const directorCameraPreview = 'director.camera_preview';
  static const directorResetView = 'director.reset_view';
  static const directorProjectMenu = 'director.project_menu';
  static const directorTitle = 'director.title';
  static const commonOpen = 'common.open';
  static const commonRestore = 'common.restore';
  static const commonIgnore = 'common.ignore';
  static const commonApply = 'common.apply';
  static const commonUndo = 'common.undo';
  static const commonRedo = 'common.redo';
  static const directorUnsaved = 'director.unsaved';
  static const directorUnsavedPrompt = 'director.unsaved_prompt';
  static const directorBlank = 'director.blank';
  static const directorActor = 'director.actor';
  static const directorPropsBasic = 'director.props_basic';
  static const directorPropsWeapons = 'director.props_weapons';
  static const directorKeys = 'director.keys';
  static const directorPropCube = 'director.prop_cube';
  static const directorPropCylinder = 'director.prop_cylinder';
  static const directorPropCone = 'director.prop_cone';
  static const directorPropSphere = 'director.prop_sphere';
  static const directorPropCapsule = 'director.prop_capsule';
  static const directorPropTorus = 'director.prop_torus';
  static const directorPropTube = 'director.prop_tube';
  static const directorPropPlane = 'director.prop_plane';
  static const directorPropTable = 'director.prop_table';
  static const directorPropChair = 'director.prop_chair';
  static const directorPropBench = 'director.prop_bench';
  static const directorPropBed = 'director.prop_bed';
  static const directorPropCounter = 'director.prop_counter';
  static const directorPropSofa = 'director.prop_sofa';
  static const directorPropCoffeeTable = 'director.prop_coffee_table';
  static const directorPropTelevision = 'director.prop_television';
  static const directorPropFloorLamp = 'director.prop_floor_lamp';
  static const directorPropSuitcase = 'director.prop_suitcase';
  static const directorPropMonitor = 'director.prop_monitor';
  static const directorPropOpenShelf = 'director.prop_open_shelf';
  static const directorPropFilingCabinet = 'director.prop_filing_cabinet';
  static const directorPropWhiteboard = 'director.prop_whiteboard';
  static const directorPropBoothSeat = 'director.prop_booth_seat';
  static const directorPropWardrobe = 'director.prop_wardrobe';
  static const directorPropRefrigerator = 'director.prop_refrigerator';
  static const directorPropDiningTable = 'director.prop_dining_table';
  static const directorPropConferenceTable = 'director.prop_conference_table';
  static const directorPropSchoolDesk = 'director.prop_school_desk';
  static const directorPropWall = 'director.prop_wall';
  static const directorPropColumn = 'director.prop_column';
  static const directorPropPlatform = 'director.prop_platform';
  static const directorPropStairs = 'director.prop_stairs';
  static const directorPropDoorframe = 'director.prop_doorframe';
  static const directorPropOfficePartition = 'director.prop_office_partition';
  static const directorPropFoldingScreen = 'director.prop_folding_screen';
  static const directorPropWindowFrameSill = 'director.prop_window_frame_sill';
  static const directorPropDoorLeaf = 'director.prop_door_leaf';
  static const directorPropRailing = 'director.prop_railing';
  static const directorPropTrashBin = 'director.prop_trash_bin';
  static const directorPropRoadBarrier = 'director.prop_road_barrier';
  static const directorPropServiceTrolley = 'director.prop_service_trolley';
  static const directorPropWheelchair = 'director.prop_wheelchair';
  static const directorPropIvStand = 'director.prop_iv_stand';
  static const directorPropHospitalBed = 'director.prop_hospital_bed';
  static const directorPropStorageChest = 'director.prop_storage_chest';
  static const directorPropWoodenRack = 'director.prop_wooden_rack';
  static const directorPropLantern = 'director.prop_lantern';
  static const directorPropCandlestick = 'director.prop_candlestick';
  static const directorPropPhone = 'director.prop_phone';
  static const directorPropCup = 'director.prop_cup';
  static const directorPropDocuments = 'director.prop_documents';
  static const directorPropBook = 'director.prop_book';
  static const directorPropKeys = 'director.prop_keys';
  static const directorPropSingleBed = 'director.prop_single_bed';
  static const directorPropDoubleBed = 'director.prop_double_bed';
  static const directorPropDagger = 'director.prop_dagger';
  static const directorPropSword = 'director.prop_sword';
  static const directorPropSaber = 'director.prop_saber';
  static const directorPropSpear = 'director.prop_spear';
  static const directorPropStaff = 'director.prop_staff';
  static const directorPropAxe = 'director.prop_axe';
  static const directorPropHammer = 'director.prop_hammer';
  static const directorPropShield = 'director.prop_shield';
  static const directorPropBow = 'director.prop_bow';
  static const directorPropPistol = 'director.prop_pistol';
  static const directorPropRifle = 'director.prop_rifle';
  static const directorPropsFurniture = 'director.props_furniture';
  static const directorPropsArchitecture = 'director.props_architecture';
  static const directorPropsStory = 'director.props_story';
  static const directorObjects = 'director.objects';
  static const directorProperties = 'director.properties';
  static const directorTimeline = 'director.timeline';
  static const directorSelect = 'director.select';
  static const directorRotate = 'director.rotate';
  static const directorEditView = 'director.edit_view';
  static const directorSetCamera = 'director.set_camera';
  static const directorPlay = 'director.play';
  static const directorExportProject = 'director.export_project';
  static const directorPosition = 'director.position';
  static const directorRotation = 'director.rotation';
  static const directorScale = 'director.scale';
  static const directorColor = 'director.color';
  static const directorPose = 'director.pose';
  static const directorPoseNeutral = 'director.pose_neutral';
  static const directorPoseHandsHips = 'director.pose_hands_hips';
  static const directorPoseArmsCrossed = 'director.pose_arms_crossed';
  static const directorPosePhone = 'director.pose_phone';
  static const directorPoseTPose = 'director.pose_t_pose';
  static const directorPoseWalk = 'director.pose_walk';
  static const directorPoseRun = 'director.pose_run';
  static const directorPoseSit = 'director.pose_sit';
  static const directorPoseSquat = 'director.pose_squat';
  static const directorPoseKneel = 'director.pose_kneel';
  static const directorPoseKneelBoth = 'director.pose_kneel_both';
  static const directorPoseLean = 'director.pose_lean';
  static const directorPoseBow = 'director.pose_bow';
  static const directorPoseThink = 'director.pose_think';
  static const directorPoseFight = 'director.pose_fight';
  static const directorPoseKick = 'director.pose_kick';
  static const directorPoseThrow = 'director.pose_throw';
  static const directorPosePush = 'director.pose_push';
  static const directorPoseWave = 'director.pose_wave';
  static const directorPosePoint = 'director.pose_point';
  static const directorPoseRaiseHand = 'director.pose_raise_hand';
  static const directorPoseCheer = 'director.pose_cheer';
  static const directorFocal = 'director.focal';
  static const directorDuration = 'director.duration';
  static const directorLandscape = 'director.landscape';
  static const directorPortrait = 'director.portrait';
  static const directorStart = 'director.start';
  static const directorEnd = 'director.end';
  static const directorPath = 'director.path';
  static const directorInvalid = 'director.invalid';
  static const directorOperationFailed = 'director.operation_failed';
  static const directorGpuFailed = 'director.gpu_failed';
  static const directorReady = 'director.ready';
  static const directorBusy = 'director.busy';
  static const directorApplyPending = 'director.apply_pending';
  static const directorFrame = 'director.frame';
  static const directorValue = 'director.value';
  static const directorLinear = 'director.linear';
  static const directorSmoothstep = 'director.smoothstep';
  static const directorHold = 'director.hold';
  static const directorZoomIn = 'director.zoom_in';
  static const directorZoomOut = 'director.zoom_out';
  static const directorBack = 'director.back';
  static const directorLoading = 'director.loading';
  static const directorTabObjects = 'director.tab_objects';
  static const directorTabActors = 'director.tab_actors';
  static const directorTabProps = 'director.tab_props';
  static const directorTabCameras = 'director.tab_cameras';
  static const directorTabMoves = 'director.tab_moves';
  static const directorRecognizeImage = 'director.recognize_image';
  static const directorRecognizeTitle = 'director.recognize_title';
  static const directorRecognizeUpload = 'director.recognize_upload';
  static const directorRecognizeCanvas = 'director.recognize_canvas';
  static const directorRecognizeScenes = 'director.recognize_scenes';
  static const directorRecognizeHistory = 'director.recognize_history';
  static const directorRecognizeEmpty = 'director.recognize_empty';
  static const directorRecognizeMode = 'director.recognize_mode';
  static const directorRecognizeInsert = 'director.recognize_insert';
  static const directorRecognizeInsertHint = 'director.recognize_insert_hint';
  static const directorRecognizeOverwrite = 'director.recognize_overwrite';
  static const directorRecognizeOverwriteHint =
      'director.recognize_overwrite_hint';
  static const directorRecognizeConfirm = 'director.recognize_confirm';
  static const directorDefaultActorMale = 'director.default_actor_male';
  static const directorDefaultActorFemale = 'director.default_actor_female';
  static const directorSearchActors = 'director.search_actors';
  static const directorActorCatalogHint = 'director.actor_catalog_hint';
  static const directorActorsLoading = 'director.actors_loading';
  static const directorActorsLoadFailed = 'director.actors_load_failed';
  static const directorActorsEmpty = 'director.actors_empty';
  static const directorActorsNoMatch = 'director.actors_no_match';
  static const directorActorsFeatured = 'director.actors_featured';
  static const directorActorsOthers = 'director.actors_others';
  static const directorActors = 'director.actors';
  static const directorProps = 'director.props';
  static const directorCameras = 'director.cameras';
  static const directorSearchObjects = 'director.search_objects';
  static const directorNoMatch = 'director.no_match';
  static const directorAddCamera = 'director.add_camera';
  static const directorApplyTo = 'director.apply_to';
  static const directorSelectCamera = 'director.select_camera';
  static const directorAiUnavailable = 'director.ai_unavailable';
  static const directorHistory = 'director.history';
  static const directorHistoryEmpty = 'director.history_empty';
  static const directorHistoryManual = 'director.history_manual';
  static const directorHistoryCurrent = 'director.history_current';
  static const directorTransform = 'director.transform';
  static const directorAppearance = 'director.appearance';
  static const directorToggleKey = 'director.toggle_key';
  static const directorHeading = 'director.heading';
  static const directorAspect = 'director.aspect';
  static const directorAspectAuto = 'director.aspect_auto';
  static const directorAspectViewport = 'director.aspect_viewport';
  static const directorSecondsUnit = 'director.seconds_unit';
  static const directorLookAt = 'director.look_at';
  static const directorLookAtNone = 'director.look_at_none';
  static const directorNoMove = 'director.no_move';
  static const directorDrivenBy = 'director.driven_by';
  static const directorExportVersions = 'director.export_versions';
  static const directorVersionMotion = 'director.version_motion';
  static const directorVersionStill = 'director.version_still';
  static const directorCameraName = 'director.camera_name';
  static const directorDefaultCamera = 'director.default_camera';
  static const directorReplaceShort = 'director.replace_short';
  static const directorAddedToCanvas = 'director.added_to_canvas';
  static const directorAddToCanvas = 'director.add_to_canvas';
  static const directorExportFailed = 'director.export_failed';
  static const directorExportProgress = 'director.export_progress';
  static const directorExportVideo = 'director.export_video';
  static const directorExportStill = 'director.export_still';
  static const directorOpeningCamera = 'director.opening_camera';
  static const directorPreviousKey = 'director.previous_key';
  static const directorNextKey = 'director.next_key';
  static const directorNeedsSubject = 'director.needs_subject';
  static const directorGroupAll = 'director.group_all';
  static const directorGroupBasic = 'director.group_basic';
  static const directorGroupFollow = 'director.group_follow';
  static const directorGroupSpace = 'director.group_space';
  static const directorMoveStatic = 'director.move_static';
  static const directorMoveDescStatic = 'director.move_desc_static';
  static const directorMovePanL = 'director.move_pan_l';
  static const directorMoveDescPanL = 'director.move_desc_pan_l';
  static const directorMovePanR = 'director.move_pan_r';
  static const directorMoveDescPanR = 'director.move_desc_pan_r';
  static const directorMoveTiltU = 'director.move_tilt_u';
  static const directorMoveDescTiltU = 'director.move_desc_tilt_u';
  static const directorMoveTiltD = 'director.move_tilt_d';
  static const directorMoveDescTiltD = 'director.move_desc_tilt_d';
  static const directorMoveDollyIn = 'director.move_dolly_in';
  static const directorMoveDescDollyIn = 'director.move_desc_dolly_in';
  static const directorMoveDollyOut = 'director.move_dolly_out';
  static const directorMoveDescDollyOut = 'director.move_desc_dolly_out';
  static const directorMoveZoomIn = 'director.move_zoom_in';
  static const directorMoveDescZoomIn = 'director.move_desc_zoom_in';
  static const directorMoveFollowPan = 'director.move_follow_pan';
  static const directorMoveDescFollowPan = 'director.move_desc_follow_pan';
  static const directorMoveFollow = 'director.move_follow';
  static const directorMoveDescFollow = 'director.move_desc_follow';
  static const directorMoveLead = 'director.move_lead';
  static const directorMoveDescLead = 'director.move_desc_lead';
  static const directorMoveOrbit = 'director.move_orbit';
  static const directorMoveDescOrbit = 'director.move_desc_orbit';
  static const directorMoveCraneUp = 'director.move_crane_up';
  static const directorMoveDescCraneUp = 'director.move_desc_crane_up';
  static const directorMoveCraneDown = 'director.move_crane_down';
  static const directorMoveDescCraneDown = 'director.move_desc_crane_down';
  static const directorMoveRiseOut = 'director.move_rise_out';
  static const directorMoveDescRiseOut = 'director.move_desc_rise_out';
  static const directorMoveZoomOut = 'director.move_zoom_out';
  static const directorMoveDescZoomOut = 'director.move_desc_zoom_out';
  static const directorMoveTruckL = 'director.move_truck_l';
  static const directorMoveDescTruckL = 'director.move_desc_truck_l';
  static const directorMoveTruckR = 'director.move_truck_r';
  static const directorMoveDescTruckR = 'director.move_desc_truck_r';
  static const directorMoveHandheld = 'director.move_handheld';
  static const directorMoveDescHandheld = 'director.move_desc_handheld';
  static const directorMoveSlideReveal = 'director.move_slide_reveal';
  static const directorMoveDescSlideReveal = 'director.move_desc_slide_reveal';
  static const directorMoveForegroundPass = 'director.move_foreground_pass';
  static const directorMoveDescForegroundPass =
      'director.move_desc_foreground_pass';
  static const directorMoveFlyThrough = 'director.move_fly_through';
  static const directorMoveDescFlyThrough = 'director.move_desc_fly_through';
  static const directorMoveWhipPan = 'director.move_whip_pan';
  static const directorMoveDescWhipPan = 'director.move_desc_whip_pan';
  static const directorMoveCrashZoom = 'director.move_crash_zoom';
  static const directorMoveDescCrashZoom = 'director.move_desc_crash_zoom';
  static const directorMoveRackFocus = 'director.move_rack_focus';
  static const directorMoveDescRackFocus = 'director.move_desc_rack_focus';
  static const directorMoveSideFollow = 'director.move_side_follow';
  static const directorMoveDescSideFollow = 'director.move_desc_side_follow';
  static const directorMoveOrbitHalf = 'director.move_orbit_half';
  static const directorMoveDescOrbitHalf = 'director.move_desc_orbit_half';
  static const directorMoveOrbitFull = 'director.move_orbit_full';
  static const directorMoveDescOrbitFull = 'director.move_desc_orbit_full';
  static const directorMoveSpiralUp = 'director.move_spiral_up';
  static const directorMoveDescSpiralUp = 'director.move_desc_spiral_up';
  static const directorMoveSpiralDown = 'director.move_spiral_down';
  static const directorMoveDescSpiralDown = 'director.move_desc_spiral_down';
  static const directorMoveAerial = 'director.move_aerial';
  static const directorMoveDescAerial = 'director.move_desc_aerial';
  static const directorMoveFpv = 'director.move_fpv';
  static const directorMoveDescFpv = 'director.move_desc_fpv';
  static const directorMoveDive = 'director.move_dive';
  static const directorMoveDescDive = 'director.move_desc_dive';
  static const directorFocusDistanceM = 'director.focus_distance_m';
  static const directorApertureFstop = 'director.aperture_fstop';
  static const directorPresetCurrent = 'director.preset_current';
  static const directorPresetFrontMedium = 'director.preset_front_medium';
  static const directorPresetFrontClose = 'director.preset_front_close';
  static const directorPresetSideClose = 'director.preset_side_close';
  static const directorPresetOverLeft = 'director.preset_over_left';
  static const directorPresetOverRight = 'director.preset_over_right';
  static const directorPresetHigh45 = 'director.preset_high_45';
  static const directorPresetLowAngle = 'director.preset_low_angle';
  static const directorPresetBird = 'director.preset_bird';
  static const directorPresetDutch = 'director.preset_dutch';
}
