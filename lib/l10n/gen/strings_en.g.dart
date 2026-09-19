///
/// Generated file. Do not edit.
///
// coverage:ignore-file
// ignore_for_file: type=lint, unused_import
// dart format off

part of 'strings.g.dart';

// Path: <root>
typedef TranslationsEn = Translations; // ignore: unused_element
class Translations with BaseTranslations<AppLocale, Translations> {
	/// Returns the current translations of the given [context].
	///
	/// Usage:
	/// final t = Translations.of(context);
	static Translations of(BuildContext context) => InheritedLocaleData.of<AppLocale, Translations>(context).translations;

	/// You can call this constructor and build your own translation instance of this locale.
	/// Constructing via the enum [AppLocale.build] is preferred.
	Translations({Map<String, Node>? overrides, PluralResolver? cardinalResolver, PluralResolver? ordinalResolver, TranslationMetadata<AppLocale, Translations>? meta})
		: assert(overrides == null, 'Set "translation_overrides: true" in order to enable this feature.'),
		  _meta = meta ?? TranslationMetadata(
		    locale: AppLocale.en,
		    overrides: overrides ?? {},
		    cardinalResolver: cardinalResolver,
		    ordinalResolver: ordinalResolver,
		  ) {
		_meta.setFlatMapFunction(_flatMapFunction);
	}

	/// Metadata for the translations of <en>.
	final TranslationMetadata<AppLocale, Translations> _meta;
	@override TranslationMetadata<AppLocale, Translations> get $meta => _meta;

	/// Access flat map
	dynamic operator[](String key) => _meta.getTranslation(key);

	late final Translations _root = this; // ignore: unused_field

	Translations $copyWith({TranslationMetadata<AppLocale, Translations>? meta}) => Translations(meta: meta ?? this.$meta);

	// Translations
	late final Translations$app$en app = Translations$app$en.internal(_root);
	late final Translations$common$en common = Translations$common$en.internal(_root);
	late final Translations$nav$en nav = Translations$nav$en.internal(_root);
	late final Translations$settings$en settings = Translations$settings$en.internal(_root);
	late final Translations$home$en home = Translations$home$en.internal(_root);
	late final Translations$daily$en daily = Translations$daily$en.internal(_root);
	late final Translations$events$en events = Translations$events$en.internal(_root);
	late final Translations$levels$en levels = Translations$levels$en.internal(_root);
	late final Translations$collections$en collections = Translations$collections$en.internal(_root);
	late final Translations$pack$en pack = Translations$pack$en.internal(_root);
	late final Translations$unlock$en unlock = Translations$unlock$en.internal(_root);
	late final Translations$myPuzzles$en myPuzzles = Translations$myPuzzles$en.internal(_root);
	late final Translations$drawer$en drawer = Translations$drawer$en.internal(_root);
	late final Translations$crop$en crop = Translations$crop$en.internal(_root);
	late final Translations$online$en online = Translations$online$en.internal(_root);
	late final Translations$share$en share = Translations$share$en.internal(_root);
	late final Translations$importPack$en importPack = Translations$importPack$en.internal(_root);
	late final Translations$background$en background = Translations$background$en.internal(_root);
	late final Translations$howTo$en howTo = Translations$howTo$en.internal(_root);
	late final Translations$logs$en logs = Translations$logs$en.internal(_root);
	late final Translations$source$en source = Translations$source$en.internal(_root);
	late final Translations$downloads$en downloads = Translations$downloads$en.internal(_root);
	late final Translations$achievements$en achievements = Translations$achievements$en.internal(_root);
	late final Translations$difficulty$en difficulty = Translations$difficulty$en.internal(_root);
	late final Translations$game$en game = Translations$game$en.internal(_root);
	late final Translations$victory$en victory = Translations$victory$en.internal(_root);
	late final Translations$continueDialog$en continueDialog = Translations$continueDialog$en.internal(_root);
	late final Translations$chooseDifficulty$en chooseDifficulty = Translations$chooseDifficulty$en.internal(_root);
	late final Translations$achievementsPage$en achievementsPage = Translations$achievementsPage$en.internal(_root);
	late final Translations$myCenter$en myCenter = Translations$myCenter$en.internal(_root);
	late final Translations$boot$en boot = Translations$boot$en.internal(_root);
}

// Path: app
class Translations$app$en {
	Translations$app$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Jigsaw Puzzle'
	String get title => 'Jigsaw Puzzle';

	/// en: 'Jigsaw Puzzle'
	String get titleFull => 'Jigsaw Puzzle';
}

// Path: common
class Translations$common$en {
	Translations$common$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'OK'
	String get ok => 'OK';

	/// en: 'Cancel'
	String get cancel => 'Cancel';

	/// en: 'Confirm'
	String get confirm => 'Confirm';

	/// en: 'Save'
	String get save => 'Save';

	/// en: 'Retry'
	String get retry => 'Retry';

	/// en: 'Clear'
	String get clear => 'Clear';

	/// en: 'Loading...'
	String get loading => 'Loading...';

	/// en: 'Calculating...'
	String get calculating => 'Calculating...';

	/// en: 'Version {version}'
	String version({required Object version}) => 'Version ${version}';

	/// en: 'Sync'
	String get sync => 'Sync';

	/// en: 'Back'
	String get back => 'Back';
}

// Path: nav
class Translations$nav$en {
	Translations$nav$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Home'
	String get home => 'Home';

	/// en: 'Daily'
	String get daily => 'Daily';

	/// en: 'Collections'
	String get collections => 'Collections';

	/// en: 'My'
	String get my => 'My';

	/// en: 'Jigsaw Puzzle'
	String get titleHome => 'Jigsaw Puzzle';

	/// en: 'Daily Challenge'
	String get titleDaily => 'Daily Challenge';

	/// en: 'Collections'
	String get titleCollections => 'Collections';

	/// en: 'My Puzzles'
	String get titleMy => 'My Puzzles';

	/// en: 'Achievements'
	String get tooltipAchievements => 'Achievements';

	/// en: 'Settings'
	String get tooltipSettings => 'Settings';
}

// Path: settings
class Translations$settings$en {
	Translations$settings$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Settings'
	String get title => 'Settings';

	/// en: 'Puzzle Player'
	String get playerTitle => 'Puzzle Player';

	/// en: 'Played for {time}'
	String playerPlayed({required Object time}) => 'Played for ${time}';

	/// en: 'Audio & Haptics'
	String get sectionsAudio => 'Audio & Haptics';

	/// en: 'Appearance'
	String get sectionsAppearance => 'Appearance';

	/// en: 'Help & Guide'
	String get sectionsHelp => 'Help & Guide';

	/// en: 'Data Management'
	String get sectionsData => 'Data Management';

	/// en: 'Language'
	String get sectionsLanguage => 'Language';

	/// en: 'Snap Sound'
	String get snapSoundTitle => 'Snap Sound';

	/// en: 'Crisp sound when pieces snap together'
	String get snapSoundDesc => 'Crisp sound when pieces snap together';

	/// en: 'Haptic Feedback'
	String get hapticTitle => 'Haptic Feedback';

	/// en: 'Subtle vibration on snap and interactions'
	String get hapticDesc => 'Subtle vibration on snap and interactions';

	/// en: 'Grid Preview on Difficulty'
	String get gridPreviewTitle => 'Grid Preview on Difficulty';

	/// en: 'Show jigsaw cut lines on difficulty preview'
	String get gridPreviewDesc => 'Show jigsaw cut lines on difficulty preview';

	/// en: 'Scatter Mode'
	String get scatterModeTitle => 'Scatter Mode';

	/// en: 'Pieces kept in bottom tray'
	String get scatterModeDescTray => 'Pieces kept in bottom tray';

	/// en: 'Pieces scattered around board'
	String get scatterModeDescTabletop => 'Pieces scattered around board';

	/// en: 'Tray'
	String get scatterTray => 'Tray';

	/// en: 'Tabletop'
	String get scatterTabletop => 'Tabletop';

	/// en: 'Background'
	String get appearanceBgTitle => 'Background';

	/// en: 'Full-screen backdrop during puzzle play'
	String get appearanceBgDesc => 'Full-screen backdrop during puzzle play';

	/// en: 'How to Play'
	String get helpTitle => 'How to Play';

	/// en: 'Gestures, group drag, ghost, and tools'
	String get helpDesc => 'Gestures, group drag, ghost, and tools';

	/// en: 'Thumbnail Cache'
	String get dataCacheTitle => 'Thumbnail Cache';

	/// en: 'Preview cache, currently {size}'
	String dataCacheDesc({required Object size}) => 'Preview cache, currently ${size}';

	/// en: 'Clear'
	String get dataClear => 'Clear';

	/// en: 'View Logs'
	String get dataViewLogsTitle => 'View Logs';

	/// en: 'Browse, filter and copy runtime logs'
	String get dataViewLogsDesc => 'Browse, filter and copy runtime logs';

	/// en: 'Version {version}'
	String footerVersion({required Object version}) => 'Version ${version}';

	/// en: 'Check for Updates'
	String get checkUpdateTitle => 'Check for Updates';

	/// en: 'Current version: {version}'
	String checkUpdateDesc({required Object version}) => 'Current version: ${version}';

	/// en: 'Checking for updates…'
	String get checkingUpdate => 'Checking for updates…';

	/// en: 'Already up to date'
	String get alreadyLatest => 'Already up to date';

	/// en: 'Failed to check for updates, please try again later'
	String get updateFailed => 'Failed to check for updates, please try again later';

	/// en: 'New Version Available {version}'
	String updateDialogTitle({required Object version}) => 'New Version Available ${version}';

	/// en: 'Size: {size}'
	String updateDialogSize({required Object size}) => 'Size: ${size}';

	/// en: 'Update Now'
	String get updateBtnNow => 'Update Now';

	/// en: 'Later'
	String get updateBtnLater => 'Later';

	/// en: 'Skip This Version'
	String get updateBtnIgnore => 'Skip This Version';

	/// en: 'Downloading update… {percent}%'
	String updateDownloading({required Object percent}) => 'Downloading update… ${percent}%';

	/// en: 'Verifying package…'
	String get updateVerifying => 'Verifying package…';

	/// en: 'Starting installation…'
	String get updateInstalling => 'Starting installation…';

	/// en: 'Failed to start install: {error}'
	String updateInstallFailed({required Object error}) => 'Failed to start install: ${error}';

	/// en: 'Thumbnail cache cleared, will regenerate on next browse'
	String get toastCacheCleared => 'Thumbnail cache cleared, will regenerate on next browse';

	/// en: 'Failed to clear cache: {error}'
	String toastCacheClearFailed({required Object error}) => 'Failed to clear cache: ${error}';

	/// en: 'Language'
	String get languageTitle => 'Language';

	/// en: 'App display language'
	String get languageDesc => 'App display language';

	/// en: 'Follow System'
	String get languageSystem => 'Follow System';

	/// en: 'Simplified Chinese'
	String get languageZh => 'Simplified Chinese';

	/// en: 'English'
	String get languageEn => 'English';

	/// en: '{count}s'
	String timeSeconds({required Object count}) => '${count}s';

	/// en: '{count} min'
	String timeMinutes({required Object count}) => '${count} min';

	/// en: '{hours}h {minutes}m'
	String timeHoursMinutes({required Object hours, required Object minutes}) => '${hours}h ${minutes}m';
}

// Path: home
class Translations$home$en {
	Translations$home$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Level image failed to load. Please retry.'
	String get loadImageFailed => 'Level image failed to load. Please retry.';

	/// en: 'Puzzle'
	String get puzzleTitle => 'Puzzle';

	/// en: 'No puzzles found in this category'
	String get emptyCategory => 'No puzzles found in this category';

	/// en: 'View All'
	String get viewAll => 'View All';

	/// en: 'All categories'
	String get allCategories => 'All categories';

	/// en: '{month}/{day} · Today's Special'
	String bannerDailyTitle({required Object month, required Object day}) => '${month}/${day} · Today\'s Special';

	/// en: 'A fresh daily puzzle to keep your brain sharp'
	String get bannerDailySub => 'A fresh daily puzzle to keep your brain sharp';

	/// en: 'Daily'
	String get bannerDailyBadge => 'Daily';
}

// Path: daily
class Translations$daily$en {
	Translations$daily$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'TODAY'
	String get todayBadge => 'TODAY';

	/// en: 'Today's Challenge'
	String get todayFallback => 'Today\'s Challenge';

	/// en: '{month}/{day} Challenge'
	String dateChallenge({required Object month, required Object day}) => '${month}/${day} Challenge';

	/// en: '⏳ Not unlocked yet. Please come back later!'
	String get notUnlocked => '⏳ Not unlocked yet. Please come back later!';

	/// en: '{month}/{day}'
	String dateCaption({required Object month, required Object day}) => '${month}/${day}';

	/// en: '{month}/{day} · Today's Challenge'
	String todayTitle({required Object month, required Object day}) => '${month}/${day} · Today\'s Challenge';

	/// en: 'Cleared · Replay'
	String get btnClearedReplay => 'Cleared · Replay';

	/// en: 'Continue'
	String get btnResume => 'Continue';

	/// en: 'Start'
	String get btnStart => 'Start';

	/// en: 'Daily progress: {done}/{total}'
	String totalProgress({required Object done, required Object total}) => 'Daily progress: ${done}/${total}';

	/// en: '{count}-day streak'
	String streakDays({required Object count}) => '${count}-day streak';

	/// en: 'Loading {month} challenges...'
	String loadingMonth({required Object month}) => 'Loading ${month} challenges...';

	/// en: 'Failed to load {month} challenges. Check your network and retry.'
	String loadMonthFailed({required Object month}) => 'Failed to load ${month} challenges. Check your network and retry.';

	/// en: 'No levels downloaded for {month} yet'
	String emptyMonth({required Object month}) => 'No levels downloaded for ${month} yet';

	/// en: 'Download this month'
	String get downloadMonth => 'Download this month';

	/// en: '{month}/{year}'
	String monthTitle({required Object month, required Object year}) => '${month}/${year}';

	/// en: 'Completed {done}/{total}'
	String monthCompleted({required Object done, required Object total}) => 'Completed ${done}/${total}';
}

// Path: events
class Translations$events$en {
	Translations$events$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'The fox couldn't find any active events'
	String get emptyTitle => 'The fox couldn\'t find any active events';

	/// en: 'Pull to refresh or check back later'
	String get emptyHint => 'Pull to refresh or check back later';

	/// en: 'Live Now'
	String get badgeActive => 'Live Now';

	/// en: 'Past Events'
	String get badgePast => 'Past Events';

	/// en: 'Offline Pack'
	String get badgeZip => 'Offline Pack';

	/// en: 'Curated Online'
	String get badgeOnline => 'Curated Online';

	/// en: 'Featured puzzle challenges'
	String get descFallback => 'Featured puzzle challenges';

	/// en: 'Limited-time event'
	String get subFallback => 'Limited-time event';

	/// en: 'Limited-time'
	String get badgeLimited => 'Limited-time';

	/// en: 'Start'
	String get enter => 'Start';

	/// en: 'Clear "{title}"'
	String clearTitle({required Object title}) => 'Clear "${title}"';

	/// en: 'Remove downloaded resources for this event? It will free {size} of disk space. You can re-download at any time.'
	String clearDesc({required Object size}) => 'Remove downloaded resources for this event?\nIt will free ${size} of disk space. You can re-download at any time.';

	/// en: 'Clear'
	String get confirmClear => 'Clear';

	/// en: 'Event storage freed'
	String get toastCleared => 'Event storage freed';

	/// en: 'Clear failed. Please retry.'
	String get toastClearFailed => 'Clear failed. Please retry.';

	/// en: 'Free event storage'
	String get deleteTooltip => 'Free event storage';
}

// Path: levels
class Translations$levels$en {
	Translations$levels$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'No levels available'
	String get empty => 'No levels available';

	/// en: '{title} · Level {index}'
	String titleOf({required Object title, required Object index}) => '${title} · Level ${index}';

	/// en: 'Retry Download'
	String get retryDownload => 'Retry Download';

	/// en: 'Retry'
	String get retryLoad => 'Retry';

	/// en: '{count} levels'
	String countLabel({required Object count}) => '${count} levels';

	/// en: '{count} levels · {size}'
	String countWithSize({required Object count, required Object size}) => '${count} levels · ${size}';

	/// en: 'Image load failed: {error}'
	String imgLoadFailed({required Object error}) => 'Image load failed: ${error}';

	/// en: 'Level image download failed. Check your network and retry.'
	String get networkFail => 'Level image download failed. Check your network and retry.';
}

// Path: collections
class Translations$collections$en {
	Translations$collections$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: '"{title}" is ready to play offline'
	String toastReady({required Object title}) => '"${title}" is ready to play offline';

	/// en: 'Download failed. Check your network and retry.'
	String get toastFailed => 'Download failed. Check your network and retry.';

	/// en: 'Download error: {error}'
	String toastError({required Object error}) => 'Download error: ${error}';

	/// en: 'Featured Collections'
	String get statsTitle => 'Featured Collections';

	/// en: '{count} sets'
	String statsCount({required Object count}) => '${count} sets';

	/// en: 'No collections yet'
	String get emptyAll => 'No collections yet';

	/// en: 'Pull to refresh to sync official content'
	String get emptyHint => 'Pull to refresh to sync official content';

	/// en: 'No collections'
	String get emptyCollections => 'No collections';

	/// en: '"{title}" is downloading ({percent}%)...'
	String downloading({required Object title, required Object percent}) => '"${title}" is downloading (${percent}%)...';

	/// en: 'Downloading "{title}"...'
	String startDownload({required Object title}) => 'Downloading "${title}"...';

	/// en: '{count} levels'
	String levelCount({required Object count}) => '${count} levels';

	/// en: 'Downloaded'
	String get badgeDownloaded => 'Downloaded';

	/// en: 'Download'
	String get badgeDownload => 'Download';

	/// en: 'Delisted'
	String get delistedBadge => 'Delisted';

	/// en: 'This content is delisted and can't be downloaded'
	String get delistedCantDownload => 'This content is delisted and can\'t be downloaded';

	/// en: 'Free collection storage'
	String get freeTooltip => 'Free collection storage';

	/// en: 'Clear "{title}"'
	String clearTitle({required Object title}) => 'Clear "${title}"';

	/// en: 'Remove downloaded resources for this collection? It will free {size} of disk space. You can re-download at any time.'
	String clearDesc({required Object size}) => 'Remove downloaded resources for this collection?\nIt will free ${size} of disk space. You can re-download at any time.';

	/// en: 'Clear'
	String get confirmClear => 'Clear';

	/// en: 'Collection storage freed'
	String get toastCleared => 'Collection storage freed';

	/// en: 'Clear failed. Please retry.'
	String get toastClearFailed => 'Clear failed. Please retry.';

	/// en: 'Official Collection'
	String get typeOfficial => 'Official Collection';

	/// en: 'Limited-time Event'
	String get typeEvent => 'Limited-time Event';
}

// Path: pack
class Translations$pack$en {
	Translations$pack$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Delete pack "{title}"'
	String deleteTitle({required Object title}) => 'Delete pack "${title}"';

	/// en: 'Delete this extension pack? {count} levels and {size} of storage will be removed.'
	String deleteDesc({required Object count, required Object size}) => 'Delete this extension pack?\n${count} levels and ${size} of storage will be removed.';

	/// en: 'Delete'
	String get confirmDelete => 'Delete';

	/// en: 'Delete failed. Please retry.'
	String get toastDeleteFailed => 'Delete failed. Please retry.';

	/// en: 'Level image is missing'
	String get imageMissing => 'Level image is missing';

	/// en: 'Delete this pack'
	String get deleteTooltip => 'Delete this pack';

	/// en: '{count} Levels'
	String levelCount({required Object count}) => '${count} Levels';

	/// en: 'This pack has no level images'
	String get emptyLevels => 'This pack has no level images';

	/// en: 'Gallery / Local'
	String get sourceLocal => 'Gallery / Local';

	/// en: 'Online'
	String get sourceNetwork => 'Online';
}

// Path: unlock
class Translations$unlock$en {
	Translations$unlock$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Earn 3 stars on {req} distinct puzzles (currently {current}/{req})'
	String stars3({required Object req, required Object current}) => 'Earn 3 stars on ${req} distinct puzzles (currently ${current}/${req})';

	/// en: 'Clear level 1 of the main campaign to unlock the Daily Challenge'
	String get daily => 'Clear level 1 of the main campaign to unlock the Daily Challenge';

	/// en: 'Clear {req} main-campaign levels to unlock Events & Packs (currently {current}/{req})'
	String eventPack({required Object req, required Object current}) => 'Clear ${req} main-campaign levels to unlock Events & Packs (currently ${current}/${req})';
}

// Path: myPuzzles
class Translations$myPuzzles$en {
	Translations$myPuzzles$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'From Gallery'
	String get actionGallery => 'From Gallery';

	/// en: 'Batch import'
	String get subBatch => 'Batch import';

	/// en: 'Import Pack'
	String get actionImportPack => 'Import Pack';

	/// en: 'ZIP packs'
	String get subZip => 'ZIP packs';

	/// en: 'Search Online'
	String get actionOnline => 'Search Online';

	/// en: 'Web gallery'
	String get subOnline => 'Web gallery';

	/// en: 'Imported Packs'
	String get importedPacksTitle => 'Imported Packs';

	/// en: '{count} packs'
	String importedPacksCount({required Object count}) => '${count} packs';

	/// en: 'Custom Puzzles'
	String get customTitle => 'Custom Puzzles';

	/// en: 'The fox is waiting with an empty basket for your puzzles'
	String get emptyTitle => 'The fox is waiting with an empty basket for your puzzles';

	/// en: 'Tap "From Gallery" or "Library" above to get started!'
	String get emptyHint => 'Tap "From Gallery" or "Library" above to get started!';

	/// en: 'Pack Collection'
	String get packBadge => 'Pack Collection';

	/// en: 'A curated collection of bonus puzzle levels'
	String get packDescFallback => 'A curated collection of bonus puzzle levels';

	/// en: '{count} levels total'
	String packTotalLevels({required Object count}) => '${count} levels total';
}

// Path: drawer
class Translations$drawer$en {
	Translations$drawer$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Library'
	String get title => 'Library';

	/// en: '{count} images'
	String count({required Object count}) => '${count} images';

	/// en: 'Clear Library'
	String get clearAllTitle => 'Clear Library';

	/// en: 'Clear all pending material images? (Puzzles already made are not affected.)'
	String get clearAllDesc => 'Clear all pending material images? (Puzzles already made are not affected.)';

	/// en: 'Clear All'
	String get clearAll => 'Clear All';

	/// en: 'No images in your library yet'
	String get emptyTitle => 'No images in your library yet';

	/// en: 'Import local photos via "From Gallery", or download them in "Search Online" — every image lands in your library, ready for puzzle making.'
	String get emptyHint => 'Import local photos via "From Gallery", or download them in "Search Online" — every image lands in your library, ready for puzzle making.';

	/// en: 'Close'
	String get close => 'Close';

	/// en: 'Make Puzzle'
	String get makePuzzle => 'Make Puzzle';

	/// en: 'Delete image'
	String get deleteImageTooltip => 'Delete image';

	/// en: 'Material file missing or already cleaned'
	String get fileMissing => 'Material file missing or already cleaned';
}

// Path: crop
class Translations$crop$en {
	Translations$crop$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Crop & Custom Puzzle'
	String get title => 'Crop & Custom Puzzle';

	/// en: 'Crop area: {width} × {height}'
	String regionLabel({required Object width, required Object height}) => 'Crop area: ${width} × ${height}';

	/// en: 'Drag to move the crop area · pinch or scroll to zoom'
	String get gestureHint => 'Drag to move the crop area · pinch or scroll to zoom';

	/// en: 'Saving...'
	String get saving => 'Saving...';

	/// en: 'Save Custom Level'
	String get saveButton => 'Save Custom Level';

	/// en: 'Optimizing image quality and creating your custom puzzle...'
	String get optimizing => 'Optimizing image quality and creating your custom puzzle...';

	/// en: 'Save failed: {error}'
	String saveFailedToast({required Object error}) => 'Save failed: ${error}';

	/// en: 'Image decode failed, please pick another image'
	String get decodeFailedToast => 'Image decode failed, please pick another image';
}

// Path: online
class Translations$online$en {
	Translations$online$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Saved to library ({width}×{height})'
	String savedBanner({required Object width, required Object height}) => 'Saved to library (${width}×${height})';

	/// en: 'From web · Tap to view'
	String get savedSourceSub => 'From web · Tap to view';

	/// en: 'This image is already in your download box'
	String get alreadyInBox => 'This image is already in your download box';

	/// en: 'Download failed: {error}'
	String downloadFailed({required Object error}) => 'Download failed: ${error}';

	/// en: 'No high-res image detected on this page. Open the photo detail page and try again.'
	String get noHighResDetected => 'No high-res image detected on this page. Open the photo detail page and try again.';

	/// en: 'Close online search'
	String get closePickerTooltip => 'Close online search';

	/// en: 'Back'
	String get backTooltip => 'Back';

	/// en: 'Refresh'
	String get refreshTooltip => 'Refresh';

	/// en: 'Extracting...'
	String get extracting => 'Extracting...';

	/// en: 'Extract this page's image'
	String get extractCurrent => 'Extract this page\'s image';

	/// en: 'Dismiss'
	String get dismissTooltip => 'Dismiss';
}

// Path: share
class Translations$share$en {
	Translations$share$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Share Result'
	String get title => 'Share Result';

	/// en: 'Export'
	String get exportTooltip => 'Export';

	/// en: 'Share card saved to temp folder'
	String get toastSaved => 'Share card saved to temp folder';

	/// en: 'Export failed: {error}'
	String toastExportFailed({required Object error}) => 'Export failed: ${error}';

	/// en: 'Puzzle Complete!'
	String get completed => 'Puzzle Complete!';

	/// en: 'Time'
	String get timeLabel => 'Time';

	/// en: 'Pieces'
	String get piecesLabel => 'Pieces';

	/// en: 'Moves'
	String get stepsLabel => 'Moves';

	/// en: 'Exporting...'
	String get exporting => 'Exporting...';

	/// en: 'Save Share Card'
	String get saveButton => 'Save Share Card';
}

// Path: importPack
class Translations$importPack$en {
	Translations$importPack$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'File selection failed: {error}'
	String pickFailed({required Object error}) => 'File selection failed: ${error}';

	/// en: 'Pick a local ZIP file or enter a download URL'
	String get hintPickFile => 'Pick a local ZIP file or enter a download URL';

	/// en: 'Extracting & parsing local pack...'
	String get extractingLocal => 'Extracting & parsing local pack...';

	/// en: 'Downloading & extracting network pack...'
	String get downloadingNet => 'Downloading & extracting network pack...';

	/// en: 'Imported "{title}" ({count} levels)'
	String imported({required Object title, required Object count}) => 'Imported "${title}" (${count} levels)';

	/// en: 'Import failed: {error}'
	String importFailedToast({required Object error}) => 'Import failed: ${error}';

	/// en: 'Import Extension Pack (.zip)'
	String get appbarTitle => 'Import Extension Pack (.zip)';

	/// en: 'Any ZIP containing JPG/PNG/WebP images can be imported; it becomes its own collection that you can delete anytime.'
	String get infoBanner => 'Any ZIP containing JPG/PNG/WebP images can be imported; it becomes its own collection that you can delete anytime.';

	/// en: 'Method 1: Choose a local file'
	String get methodLocal => 'Method 1: Choose a local file';

	/// en: 'Tap the button on the right to pick a .zip file'
	String get browseHint => 'Tap the button on the right to pick a .zip file';

	/// en: 'Browse...'
	String get browse => 'Browse...';

	/// en: 'Method 2: Enter a download URL'
	String get methodNetwork => 'Method 2: Enter a download URL';

	/// en: 'Start Import'
	String get startImport => 'Start Import';
}

// Path: background
class Translations$background$en {
	Translations$background$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Change Puzzle Background'
	String get title => 'Change Puzzle Background';

	/// en: 'Table {index}'
	String tableLabel({required Object index}) => 'Table ${index}';

	List<String> get colorLabels => [
		'Warm Oatmeal',
		'Misty Gray',
		'Sage Green',
		'Misty Blue',
		'Dusty Mauve',
		'Dark Slate',
	];
}

// Path: howTo
class Translations$howTo$en {
	Translations$howTo$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'How to Play'
	String get title => 'How to Play';

	/// en: 'Get Started with Jigsaw Puzzles'
	String get welcomeTitle => 'Get Started with Jigsaw Puzzles';

	/// en: 'Master these core gestures and helper tools, and you will breeze through even the hardest puzzles!'
	String get welcomeSub => 'Master these core gestures and helper tools, and you will breeze through even the hardest puzzles!';

	late final Translations$howTo$t1$en t1 = Translations$howTo$t1$en.internal(_root);
	late final Translations$howTo$t2$en t2 = Translations$howTo$t2$en.internal(_root);
	late final Translations$howTo$t3$en t3 = Translations$howTo$t3$en.internal(_root);
	late final Translations$howTo$t4$en t4 = Translations$howTo$t4$en.internal(_root);
	late final Translations$howTo$t5$en t5 = Translations$howTo$t5$en.internal(_root);
	late final Translations$howTo$t6$en t6 = Translations$howTo$t6$en.internal(_root);
}

// Path: logs
class Translations$logs$en {
	Translations$logs$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Runtime Logs'
	String get title => 'Runtime Logs';

	/// en: 'Filter: '
	String get filterPrefix => 'Filter: ';

	/// en: 'All'
	String get filterAll => 'All';

	/// en: 'Back to top (newest)'
	String get scrollTopTooltip => 'Back to top (newest)';

	/// en: 'Copy logs'
	String get copyTooltip => 'Copy logs';

	/// en: 'Copy current view ({count})'
	String copyFiltered({required Object count}) => 'Copy current view (${count})';

	/// en: 'Copy all logs ({count})'
	String copyAll({required Object count}) => 'Copy all logs (${count})';

	/// en: 'No logs to copy'
	String get nothingToCopy => 'No logs to copy';

	/// en: 'Copied {count} logs from current view'
	String copiedFiltered({required Object count}) => 'Copied ${count} logs from current view';

	/// en: 'Copied all {count} logs'
	String copiedAll({required Object count}) => 'Copied all ${count} logs';

	/// en: 'Clear logs'
	String get clearTooltip => 'Clear logs';

	/// en: 'Clear all logs?'
	String get clearConfirmTitle => 'Clear all logs?';

	/// en: 'Deletes log files on disk and clears the in-memory records. This cannot be undone. Logging restarts from scratch, so future copies will be much smaller.'
	String get clearConfirmDesc => 'Deletes log files on disk and clears the in-memory records. This cannot be undone.\nLogging restarts from scratch, so future copies will be much smaller.';

	/// en: 'Clear logs'
	String get clearConfirmBtn => 'Clear logs';

	/// en: 'Logs cleared, recording restarted from scratch'
	String get clearedToast => 'Logs cleared, recording restarted from scratch';

	/// en: 'No logs under the current filter'
	String get emptyFiltered => 'No logs under the current filter';

	/// en: 'Loading logs...'
	String get loading => 'Loading logs...';

	/// en: 'Close'
	String get close => 'Close';
}

// Path: source
class Translations$source$en {
	Translations$source$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Main'
	String get main => 'Main';

	/// en: 'Daily'
	String get daily => 'Daily';

	/// en: 'Custom'
	String get custom => 'Custom';

	/// en: 'Pack'
	String get pack => 'Pack';

	/// en: 'Gallery'
	String get album => 'Gallery';

	/// en: 'Online'
	String get online => 'Online';

	/// en: 'Official'
	String get preset => 'Official';

	/// en: 'Official Collection'
	String get official => 'Official Collection';

	/// en: 'Limited-time'
	String get event => 'Limited-time';
}

// Path: downloads
class Translations$downloads$en {
	Translations$downloads$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: '4K Ultra HD'
	String get q4k => '4K Ultra HD';

	/// en: '2K QHD'
	String get q2k => '2K QHD';

	/// en: 'FHD 1080p'
	String get q1080 => 'FHD 1080p';

	/// en: 'HD 720p'
	String get q720 => 'HD 720p';

	/// en: 'SD'
	String get qsd => 'SD';
}

// Path: achievements
class Translations$achievements$en {
	Translations$achievements$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations
	late final Translations$achievements$first_win$en first_win = Translations$achievements$first_win$en.internal(_root);
	late final Translations$achievements$win_10$en win_10 = Translations$achievements$win_10$en.internal(_root);
	late final Translations$achievements$win_50$en win_50 = Translations$achievements$win_50$en.internal(_root);
	late final Translations$achievements$win_100$en win_100 = Translations$achievements$win_100$en.internal(_root);
	late final Translations$achievements$star_1$en star_1 = Translations$achievements$star_1$en.internal(_root);
	late final Translations$achievements$star_10$en star_10 = Translations$achievements$star_10$en.internal(_root);
	late final Translations$achievements$star_30$en star_30 = Translations$achievements$star_30$en.internal(_root);
	late final Translations$achievements$star_50$en star_50 = Translations$achievements$star_50$en.internal(_root);
	late final Translations$achievements$tier_l3$en tier_l3 = Translations$achievements$tier_l3$en.internal(_root);
	late final Translations$achievements$tier_l4$en tier_l4 = Translations$achievements$tier_l4$en.internal(_root);
	late final Translations$achievements$tier_l5$en tier_l5 = Translations$achievements$tier_l5$en.internal(_root);
	late final Translations$achievements$tier_l6$en tier_l6 = Translations$achievements$tier_l6$en.internal(_root);
	late final Translations$achievements$custom_1$en custom_1 = Translations$achievements$custom_1$en.internal(_root);
	late final Translations$achievements$custom_5$en custom_5 = Translations$achievements$custom_5$en.internal(_root);
	late final Translations$achievements$no_hint_win$en no_hint_win = Translations$achievements$no_hint_win$en.internal(_root);
	late final Translations$achievements$speed_10min$en speed_10min = Translations$achievements$speed_10min$en.internal(_root);
	late final Translations$achievements$night_owl$en night_owl = Translations$achievements$night_owl$en.internal(_root);
	late final Translations$achievements$snap_100$en snap_100 = Translations$achievements$snap_100$en.internal(_root);
	late final Translations$achievements$snap_500$en snap_500 = Translations$achievements$snap_500$en.internal(_root);
	late final Translations$achievements$snap_2000$en snap_2000 = Translations$achievements$snap_2000$en.internal(_root);
	late final Translations$achievements$time_30m$en time_30m = Translations$achievements$time_30m$en.internal(_root);
	late final Translations$achievements$time_2h$en time_2h = Translations$achievements$time_2h$en.internal(_root);
	late final Translations$achievements$time_10h$en time_10h = Translations$achievements$time_10h$en.internal(_root);
	late final Translations$achievements$daily_7$en daily_7 = Translations$achievements$daily_7$en.internal(_root);
	late final Translations$achievements$master_all$en master_all = Translations$achievements$master_all$en.internal(_root);
}

// Path: difficulty
class Translations$difficulty$en {
	Translations$difficulty$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations
	late final Translations$difficulty$tier$en tier = Translations$difficulty$tier$en.internal(_root);
	late final Translations$difficulty$estimated$en estimated = Translations$difficulty$estimated$en.internal(_root);
	late final Translations$difficulty$aspect$en aspect = Translations$difficulty$aspect$en.internal(_root);

	/// en: '{cols} x {rows} ({count} pieces)'
	String pieceCount({required Object cols, required Object rows, required Object count}) => '${cols} x ${rows} (${count} pieces)';

	/// en: 'Recommended'
	String get recommended => 'Recommended';
}

// Path: game
class Translations$game$en {
	Translations$game$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Level {index}'
	String titleLevel({required Object index}) => 'Level ${index}';

	/// en: '{date} Daily'
	String titleDaily({required Object date}) => '${date} Daily';

	/// en: 'Custom Puzzle'
	String get titleCustom => 'Custom Puzzle';

	/// en: '{title}'
	String titlePack({required Object title}) => '${title}';

	/// en: 'Back'
	String get tooltipBack => 'Back';

	/// en: 'Edge pieces only'
	String get tooltipEdges => 'Edge pieces only';

	/// en: 'Show all pieces'
	String get tooltipEdgesAll => 'Show all pieces';

	/// en: 'Hint'
	String get tooltipHint => 'Hint';

	/// en: 'Ghost {opacity}%'
	String tooltipGhost({required Object opacity}) => 'Ghost ${opacity}%';

	/// en: 'Ghost off'
	String get tooltipGhostOff => 'Ghost off';

	/// en: 'Preview'
	String get tooltipPreview => 'Preview';

	/// en: 'Organize tray'
	String get tooltipOrganize => 'Organize tray';

	/// en: 'Change background'
	String get tooltipChangeBg => 'Change background';

	/// en: 'Not enough coins (need {price}, you have {coins})'
	String hintNotEnoughCoins({required Object price, required Object coins}) => 'Not enough coins (need ${price}, you have ${coins})';

	/// en: 'Image decode failed, please retry'
	String get imageDecodeFailed => 'Image decode failed, please retry';

	/// en: 'Tap anywhere to return'
	String get tapToReturn => 'Tap anywhere to return';

	/// en: 'Reset'
	String get zoomReset => 'Reset';

	/// en: '{percent}%'
	String progress({required Object percent}) => '${percent}%';
}

// Path: victory
class Translations$victory$en {
	Translations$victory$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Puzzle Complete!'
	String get title => 'Puzzle Complete!';

	/// en: '(one) {1 Star} (other) {{count} Stars}'
	String stars({required num count}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(count,
		one: '1 Star',
		other: '${count} Stars',
	);

	/// en: 'Time: {time}'
	String time({required Object time}) => 'Time: ${time}';

	/// en: '{count} pieces'
	String pieces({required Object count}) => '${count} pieces';

	/// en: '+{coins} coins'
	String coinsReward({required Object coins}) => '+${coins} coins';

	/// en: '{count} new achievements'
	String newAchievements({required Object count}) => '${count} new achievements';

	/// en: 'Next Level'
	String get btnNext => 'Next Level';

	/// en: 'Share'
	String get btnShare => 'Share';

	/// en: 'View Puzzle'
	String get btnView => 'View Puzzle';

	/// en: 'Exit'
	String get btnExit => 'Exit';

	/// en: 'Save Wallpaper'
	String get btnSaveWallpaper => 'Save Wallpaper';

	/// en: 'Perfect!'
	String get perfect => 'Perfect!';

	/// en: 'Great!'
	String get great => 'Great!';

	/// en: 'Close (Esc)'
	String get btnClose => 'Close (Esc)';

	/// en: 'Wallpaper saved to local folder'
	String get toastWallpaperSaved => 'Wallpaper saved to local folder';

	/// en: 'Failed to save wallpaper: {error}'
	String toastSaveWallpaperFailed({required Object error}) => 'Failed to save wallpaper: ${error}';
}

// Path: continueDialog
class Translations$continueDialog$en {
	Translations$continueDialog$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Progress'
	String get progressLabel => 'Progress';

	/// en: 'Time Spent'
	String get timeLabel => 'Time Spent';

	/// en: 'Spec: {key}'
	String spec({required Object key}) => 'Spec: ${key}';

	/// en: 'Spec: {key} ({count} pieces)'
	String specPieces({required Object key, required Object count}) => 'Spec: ${key} (${count} pieces)';

	/// en: 'Pieces {count}'
	String piecesCount({required Object count}) => 'Pieces ${count}';

	/// en: 'The little fox is waiting for you to finish this puzzle!'
	String get foxHint => 'The little fox is waiting for you to finish this puzzle!';

	/// en: 'Restart this puzzle?'
	String get restartTitle => 'Restart this puzzle?';

	/// en: 'This will clear the saved progress for this difficulty. It cannot be undone. Restart now?'
	String get restartDesc => 'This will clear the saved progress for this difficulty. It cannot be undone. Restart now?';

	/// en: 'Restart'
	String get btnRestart => 'Restart';

	/// en: 'Yes, Restart'
	String get restartConfirm => 'Yes, Restart';

	/// en: 'Keep Going'
	String get btnResume => 'Keep Going';
}

// Path: chooseDifficulty
class Translations$chooseDifficulty$en {
	Translations$chooseDifficulty$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Choose Difficulty'
	String get title => 'Choose Difficulty';

	/// en: '{count} pieces'
	String pieces({required Object count}) => '${count} pieces';

	/// en: 'Recommended'
	String get recommended => 'Recommended';

	/// en: 'Locked'
	String get locked => 'Locked';

	/// en: 'Level locked'
	String get lockedByLevel => 'Level locked';

	/// en: 'Complete previous level to unlock'
	String get lockedDesc => 'Complete previous level to unlock';

	/// en: 'Start'
	String get btnStart => 'Start';

	/// en: 'Replay'
	String get btnReplay => 'Replay';

	/// en: 'Continue ({percent}%)'
	String btnContinue({required Object percent}) => 'Continue (${percent}%)';

	/// en: 'Reset progress'
	String get btnReset => 'Reset progress';

	/// en: 'Saved progress {percent}% detected'
	String savedProgress({required Object percent}) => 'Saved progress ${percent}% detected';

	/// en: 'Preview with cut lines'
	String get previewHint => 'Preview with cut lines';

	/// en: 'Cleared'
	String get badgeCleared => 'Cleared';

	/// en: 'Delete Custom Puzzle'
	String get deleteTitle => 'Delete Custom Puzzle';

	/// en: 'Delete "{title}" permanently? This cannot be undone.'
	String deleteDesc({required Object title}) => 'Delete "${title}" permanently? This cannot be undone.';

	/// en: 'Delete this custom puzzle permanently? This cannot be undone.'
	String get deleteDescGeneric => 'Delete this custom puzzle permanently? This cannot be undone.';

	/// en: 'Delete'
	String get deleteConfirm => 'Delete';

	/// en: 'Delete this custom puzzle'
	String get deleteTooltip => 'Delete this custom puzzle';

	/// en: 'Add to favorites'
	String get favAdd => 'Add to favorites';

	/// en: 'Remove from favorites'
	String get favRemove => 'Remove from favorites';

	/// en: 'Earn {gap} more 3-star puzzles to unlock {tier}'
	String lockedProgress({required Object gap, required Object tier}) => 'Earn ${gap} more 3-star puzzles to unlock ${tier}';
}

// Path: achievementsPage
class Translations$achievementsPage$en {
	Translations$achievementsPage$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Achievements'
	String get title => 'Achievements';

	/// en: 'Stats'
	String get stats => 'Stats';

	/// en: 'Clears & Stars'
	String get groupClears => 'Clears & Stars';

	/// en: 'Journey & Assets'
	String get groupAssets => 'Journey & Assets';

	/// en: 'Total Stars'
	String get totalStars => 'Total Stars';

	/// en: 'Solved'
	String get totalSolved => 'Solved';

	/// en: 'Snaps'
	String get totalSnaps => 'Snaps';

	/// en: 'Play Time'
	String get totalTime => 'Play Time';

	/// en: '3-Star Clears'
	String get threeStarCount => '3-Star Clears';

	/// en: 'Coins'
	String get coinsOwned => 'Coins';

	/// en: 'Achievement Wall'
	String get wall => 'Achievement Wall';

	/// en: '{count} achievements total'
	String wallCount({required Object count}) => '${count} achievements total';

	/// en: 'Unlocked'
	String get unlocked => 'Unlocked';

	/// en: 'Locked'
	String get locked => 'Locked';

	/// en: 'Claim'
	String get claim => 'Claim';

	/// en: 'Claimed'
	String get claimed => 'Claimed';

	/// en: 'Claimed: {reward}'
	String claimedReward({required Object reward}) => 'Claimed: ${reward}';

	/// en: 'Failed to claim reward, please try again'
	String get claimFailed => 'Failed to claim reward, please try again';

	/// en: '{count} coins'
	String coins({required Object count}) => '${count} coins';
}

// Path: myCenter
class Translations$myCenter$en {
	Translations$myCenter$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations
	late final Translations$myCenter$tabs$en tabs = Translations$myCenter$tabs$en.internal(_root);
	late final Translations$myCenter$topActions$en topActions = Translations$myCenter$topActions$en.internal(_root);
	late final Translations$myCenter$empty$en empty = Translations$myCenter$empty$en.internal(_root);
	late final Translations$myCenter$card$en card = Translations$myCenter$card$en.internal(_root);
	late final Translations$myCenter$orphanDialog$en orphanDialog = Translations$myCenter$orphanDialog$en.internal(_root);
	late final Translations$myCenter$toast$en toast = Translations$myCenter$toast$en.internal(_root);
}

// Path: boot
class Translations$boot$en {
	Translations$boot$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Initializing game content…'
	String get initTitle => 'Initializing game content…';

	/// en: 'First launch downloads the puzzle library over the network.'
	String get initSubtitle => 'First launch downloads the puzzle library over the network.';

	/// en: 'Initialization failed'
	String get failedTitle => 'Initialization failed';

	/// en: 'Cannot reach the content server. Check your network and retry.'
	String get failedDesc => 'Cannot reach the content server. Check your network and retry.';

	/// en: 'Retry'
	String get retry => 'Retry';
}

// Path: howTo.t1
class Translations$howTo$t1$en {
	Translations$howTo$t1$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Drag & Snap'
	String get title => 'Drag & Snap';

	/// en: 'Drag a piece with one finger near its correct spot; it snaps into place with a crisp click.'
	String get page => 'Drag a piece with one finger near its correct spot; it snaps into place with a crisp click.';
}

// Path: howTo.t2
class Translations$howTo$t2$en {
	Translations$howTo$t2$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Group Merge (Cluster)'
	String get title => 'Group Merge (Cluster)';

	/// en: 'Connected pieces can be joined anywhere on the tray or canvas, even before reaching their correct cells, then moved as a group.'
	String get page => 'Connected pieces can be joined anywhere on the tray or canvas, even before reaching their correct cells, then moved as a group.';
}

// Path: howTo.t3
class Translations$howTo$t3$en {
	Translations$howTo$t3$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Pinch to Zoom & Pan'
	String get title => 'Pinch to Zoom & Pan';

	/// en: 'Pinch to zoom the board seamlessly; two-finger drag or middle-mouse drag pans the canvas, making it easy to align fine details.'
	String get page => 'Pinch to zoom the board seamlessly; two-finger drag or middle-mouse drag pans the canvas, making it easy to align fine details.';
}

// Path: howTo.t4
class Translations$howTo$t4$en {
	Translations$howTo$t4$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Ghost Guide Overlay'
	String get title => 'Ghost Guide Overlay';

	/// en: 'Tap the ghost icon in the top bar to overlay a 20%/45% translucent image, helping you spot lines and colors to place pieces faster.'
	String get page => 'Tap the ghost icon in the top bar to overlay a 20%/45% translucent image, helping you spot lines and colors to place pieces faster.';
}

// Path: howTo.t5
class Translations$howTo$t5$en {
	Translations$howTo$t5$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Edge Pieces Filter'
	String get title => 'Edge Pieces Filter';

	/// en: 'Tap the edge filter icon to highlight flat outer pieces and dim inner ones, so you can build the frame first.'
	String get page => 'Tap the edge filter icon to highlight flat outer pieces and dim inner ones, so you can build the frame first.';
}

// Path: howTo.t6
class Translations$howTo$t6$en {
	Translations$howTo$t6$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Organize Tray'
	String get title => 'Organize Tray';

	/// en: 'Scattered single pieces on the board can be tidied into the tray instantly with the broom icon, restoring a clean view.'
	String get page => 'Scattered single pieces on the board can be tidied into the tray instantly with the broom icon, restoring a clean view.';
}

// Path: achievements.first_win
class Translations$achievements$first_win$en {
	Translations$achievements$first_win$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'First Win'
	String get title => 'First Win';

	/// en: 'Complete your first puzzle'
	String get desc => 'Complete your first puzzle';
}

// Path: achievements.win_10
class Translations$achievements$win_10$en {
	Translations$achievements$win_10$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Practice Makes Perfect'
	String get title => 'Practice Makes Perfect';

	/// en: 'Complete 10 puzzles'
	String get desc => 'Complete 10 puzzles';
}

// Path: achievements.win_50
class Translations$achievements$win_50$en {
	Translations$achievements$win_50$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Puzzle Expert'
	String get title => 'Puzzle Expert';

	/// en: 'Complete 50 puzzles'
	String get desc => 'Complete 50 puzzles';
}

// Path: achievements.win_100
class Translations$achievements$win_100$en {
	Translations$achievements$win_100$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Puzzle Master'
	String get title => 'Puzzle Master';

	/// en: 'Complete 100 puzzles'
	String get desc => 'Complete 100 puzzles';
}

// Path: achievements.star_1
class Translations$achievements$star_1$en {
	Translations$achievements$star_1$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Three-Star Debut'
	String get title => 'Three-Star Debut';

	/// en: 'Earn your first 3-star rating'
	String get desc => 'Earn your first 3-star rating';
}

// Path: achievements.star_10
class Translations$achievements$star_10$en {
	Translations$achievements$star_10$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Shining Star'
	String get title => 'Shining Star';

	/// en: 'Earn 10 three-star ratings'
	String get desc => 'Earn 10 three-star ratings';
}

// Path: achievements.star_30
class Translations$achievements$star_30$en {
	Translations$achievements$star_30$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Starry Sky'
	String get title => 'Starry Sky';

	/// en: 'Earn 30 three-star ratings'
	String get desc => 'Earn 30 three-star ratings';
}

// Path: achievements.star_50
class Translations$achievements$star_50$en {
	Translations$achievements$star_50$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Star Lord'
	String get title => 'Star Lord';

	/// en: 'Earn 50 three-star ratings'
	String get desc => 'Earn 50 three-star ratings';
}

// Path: achievements.tier_l3
class Translations$achievements$tier_l3$en {
	Translations$achievements$tier_l3$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Intermediate Challenge'
	String get title => 'Intermediate Challenge';

	/// en: 'Complete a Medium (L3) or higher puzzle'
	String get desc => 'Complete a Medium (L3) or higher puzzle';
}

// Path: achievements.tier_l4
class Translations$achievements$tier_l4$en {
	Translations$achievements$tier_l4$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Advanced Expert'
	String get title => 'Advanced Expert';

	/// en: 'Complete a Hard (L4) or higher puzzle'
	String get desc => 'Complete a Hard (L4) or higher puzzle';
}

// Path: achievements.tier_l5
class Translations$achievements$tier_l5$en {
	Translations$achievements$tier_l5$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Conqueror'
	String get title => 'Conqueror';

	/// en: 'Complete an Expert (L5) or higher puzzle'
	String get desc => 'Complete an Expert (L5) or higher puzzle';
}

// Path: achievements.tier_l6
class Translations$achievements$tier_l6$en {
	Translations$achievements$tier_l6$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Ultimate Summit'
	String get title => 'Ultimate Summit';

	/// en: 'Complete a Master (L6) puzzle'
	String get desc => 'Complete a Master (L6) puzzle';
}

// Path: achievements.custom_1
class Translations$achievements$custom_1$en {
	Translations$achievements$custom_1$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Creator'
	String get title => 'Creator';

	/// en: 'Complete 1 custom puzzle'
	String get desc => 'Complete 1 custom puzzle';
}

// Path: achievements.custom_5
class Translations$achievements$custom_5$en {
	Translations$achievements$custom_5$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Boundless Creativity'
	String get title => 'Boundless Creativity';

	/// en: 'Complete 5 custom puzzles'
	String get desc => 'Complete 5 custom puzzles';
}

// Path: achievements.no_hint_win
class Translations$achievements$no_hint_win$en {
	Translations$achievements$no_hint_win$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Dexterous'
	String get title => 'Dexterous';

	/// en: 'Complete a puzzle without hints'
	String get desc => 'Complete a puzzle without hints';
}

// Path: achievements.speed_10min
class Translations$achievements$speed_10min$en {
	Translations$achievements$speed_10min$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Speedster'
	String get title => 'Speedster';

	/// en: 'Complete a 100+ piece puzzle within 10 minutes'
	String get desc => 'Complete a 100+ piece puzzle within 10 minutes';
}

// Path: achievements.night_owl
class Translations$achievements$night_owl$en {
	Translations$achievements$night_owl$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Night Owl'
	String get title => 'Night Owl';

	/// en: 'Complete a puzzle between 22:00 - 05:00'
	String get desc => 'Complete a puzzle between 22:00 - 05:00';
}

// Path: achievements.snap_100
class Translations$achievements$snap_100$en {
	Translations$achievements$snap_100$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'First Touch'
	String get title => 'First Touch';

	/// en: 'Snap 100 pieces'
	String get desc => 'Snap 100 pieces';
}

// Path: achievements.snap_500
class Translations$achievements$snap_500$en {
	Translations$achievements$snap_500$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Getting Better'
	String get title => 'Getting Better';

	/// en: 'Snap 500 pieces'
	String get desc => 'Snap 500 pieces';
}

// Path: achievements.snap_2000
class Translations$achievements$snap_2000$en {
	Translations$achievements$snap_2000$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Tempered'
	String get title => 'Tempered';

	/// en: 'Snap 2000 pieces'
	String get desc => 'Snap 2000 pieces';
}

// Path: achievements.time_30m
class Translations$achievements$time_30m$en {
	Translations$achievements$time_30m$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Immersed'
	String get title => 'Immersed';

	/// en: 'Play for 30 minutes total'
	String get desc => 'Play for 30 minutes total';
}

// Path: achievements.time_2h
class Translations$achievements$time_2h$en {
	Translations$achievements$time_2h$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Puzzle Enthusiast'
	String get title => 'Puzzle Enthusiast';

	/// en: 'Play for 2 hours total'
	String get desc => 'Play for 2 hours total';
}

// Path: achievements.time_10h
class Translations$achievements$time_10h$en {
	Translations$achievements$time_10h$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Time Flies'
	String get title => 'Time Flies';

	/// en: 'Play for 10 hours total'
	String get desc => 'Play for 10 hours total';
}

// Path: achievements.daily_7
class Translations$achievements$daily_7$en {
	Translations$achievements$daily_7$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Daily Dedication'
	String get title => 'Daily Dedication';

	/// en: 'Complete 7 daily challenges'
	String get desc => 'Complete 7 daily challenges';
}

// Path: achievements.master_all
class Translations$achievements$master_all$en {
	Translations$achievements$master_all$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Puzzle Grandmaster'
	String get title => 'Puzzle Grandmaster';

	/// en: 'Achieve all 24 achievements'
	String get desc => 'Achieve all 24 achievements';
}

// Path: difficulty.tier
class Translations$difficulty$tier$en {
	Translations$difficulty$tier$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Novice Easy'
	String get l1 => 'Novice Easy';

	/// en: 'Beginner+'
	String get l1_5 => 'Beginner+';

	/// en: 'Beginner'
	String get l2 => 'Beginner';

	/// en: 'Medium'
	String get l3 => 'Medium';

	/// en: 'Hard'
	String get l4 => 'Hard';

	/// en: 'Expert'
	String get l5 => 'Expert';

	/// en: 'Master'
	String get l6 => 'Master';

	/// en: 'Grandmaster'
	String get l7 => 'Grandmaster';
}

// Path: difficulty.estimated
class Translations$difficulty$estimated$en {
	Translations$difficulty$estimated$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: '1-3 min'
	String get l1 => '1-3 min';

	/// en: '2-4 min'
	String get l1_5 => '2-4 min';

	/// en: '5-8 min'
	String get l2 => '5-8 min';

	/// en: '12-18 min'
	String get l3 => '12-18 min';

	/// en: '25-35 min'
	String get l4 => '25-35 min';

	/// en: '50-75 min'
	String get l5 => '50-75 min';

	/// en: '1.5-3 hrs'
	String get l6 => '1.5-3 hrs';

	/// en: '3-5 hrs'
	String get l7 => '3-5 hrs';
}

// Path: difficulty.aspect
class Translations$difficulty$aspect$en {
	Translations$difficulty$aspect$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: '1:1 Square'
	String get square => '1:1 Square';

	/// en: '2:3 Portrait'
	String get portrait2x3 => '2:3 Portrait';

	/// en: '3:2 Landscape'
	String get landscape3x2 => '3:2 Landscape';

	/// en: '3:4 Portrait'
	String get portrait3x4 => '3:4 Portrait';

	/// en: '4:3 Landscape'
	String get landscape4x3 => '4:3 Landscape';
}

// Path: myCenter.tabs
class Translations$myCenter$tabs$en {
	Translations$myCenter$tabs$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Active ({count})'
	String inProgress({required Object count}) => 'Active (${count})';

	/// en: 'Saved ({count})'
	String favorites({required Object count}) => 'Saved (${count})';

	/// en: 'Done ({count})'
	String completed({required Object count}) => 'Done (${count})';

	/// en: 'Custom ({count})'
	String custom({required Object count}) => 'Custom (${count})';
}

// Path: myCenter.topActions
class Translations$myCenter$topActions$en {
	Translations$myCenter$topActions$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Gallery'
	String get gallery => 'Gallery';

	/// en: 'Custom'
	String get gallerySub => 'Custom';

	/// en: 'Online'
	String get online => 'Online';

	/// en: 'Search'
	String get onlineSub => 'Search';

	/// en: 'Archive'
	String get archive => 'Archive';

	/// en: '{count} images'
	String archiveSub({required Object count}) => '${count} images';

	/// en: 'Import'
	String get import => 'Import';

	/// en: 'ZIP'
	String get importSub => 'ZIP';
}

// Path: myCenter.empty
class Translations$myCenter$empty$en {
	Translations$myCenter$empty$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'No puzzles in progress'
	String get inProgressTitle => 'No puzzles in progress';

	/// en: 'Pick a puzzle and start!'
	String get inProgressSub => 'Pick a puzzle and start!';

	/// en: 'No favorites yet'
	String get favoritesTitle => 'No favorites yet';

	/// en: 'Tap heart in difficulty sheet to favorite'
	String get favoritesSub => 'Tap heart in difficulty sheet to favorite';

	/// en: 'No completed puzzles yet'
	String get completedTitle => 'No completed puzzles yet';

	/// en: 'Complete any puzzle to see it here!'
	String get completedSub => 'Complete any puzzle to see it here!';

	/// en: 'No custom puzzles'
	String get customTitle => 'No custom puzzles';

	/// en: 'Use Gallery to create your own!'
	String get customSub => 'Use Gallery to create your own!';

	/// en: 'Explore'
	String get goExplore => 'Explore';

	/// en: 'Create from Gallery'
	String get create => 'Create from Gallery';
}

// Path: myCenter.card
class Translations$myCenter$card$en {
	Translations$myCenter$card$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Expired'
	String get orphan => 'Expired';

	/// en: 'Tap to clean'
	String get orphanDesc => 'Tap to clean';

	/// en: '{percent}%'
	String progress({required Object percent}) => '${percent}%';

	/// en: 'Retry'
	String get retry => 'Retry';
}

// Path: myCenter.orphanDialog
class Translations$myCenter$orphanDialog$en {
	Translations$myCenter$orphanDialog$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Puzzle source unavailable'
	String get title => 'Puzzle source unavailable';

	/// en: 'This record's puzzle image is currently unavailable, but the record can stay. Remove "{title}" from your records and favorites only? Downloaded images are not affected.'
	String desc({required Object title}) => 'This record\'s puzzle image is currently unavailable, but the record can stay.\nRemove "${title}" from your records and favorites only? Downloaded images are not affected.';

	/// en: 'Keep it'
	String get keep => 'Keep it';

	/// en: 'Remove'
	String get remove => 'Remove';
}

// Path: myCenter.toast
class Translations$myCenter$toast$en {
	Translations$myCenter$toast$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Imported {count} images to your library'
	String importSuccess({required Object count}) => 'Imported ${count} images to your library';

	/// en: 'Failed to pick images: {error}'
	String importFailed({required Object error}) => 'Failed to pick images: ${error}';

	/// en: 'WebView2 runtime is not installed; online image search is unavailable.'
	String get webviewMissing => 'WebView2 runtime is not installed; online image search is unavailable.';

	/// en: 'Image unavailable — this record can't be played yet'
	String get imageNotFound => 'Image unavailable — this record can\'t be played yet';

	/// en: 'Image not ready. Reconnect and retry.'
	String get imageNotReady => 'Image not ready. Reconnect and retry.';

	/// en: 'Failed to open. Please retry.'
	String get openFailed => 'Failed to open. Please retry.';
}

/// The flat map containing all translations for locale <en>.
/// Only for edge cases! For simple maps, use the map function of this library.
///
/// The Dart AOT compiler has issues with very large switch statements,
/// so the map is split into smaller functions (512 entries each).
extension on Translations {
	dynamic _flatMapFunction(String path) {
		return switch (path) {
			'app.title' => 'Jigsaw Puzzle',
			'app.titleFull' => 'Jigsaw Puzzle',
			'common.ok' => 'OK',
			'common.cancel' => 'Cancel',
			'common.confirm' => 'Confirm',
			'common.save' => 'Save',
			'common.retry' => 'Retry',
			'common.clear' => 'Clear',
			'common.loading' => 'Loading...',
			'common.calculating' => 'Calculating...',
			'common.version' => ({required Object version}) => 'Version ${version}',
			'common.sync' => 'Sync',
			'common.back' => 'Back',
			'nav.home' => 'Home',
			'nav.daily' => 'Daily',
			'nav.collections' => 'Collections',
			'nav.my' => 'My',
			'nav.titleHome' => 'Jigsaw Puzzle',
			'nav.titleDaily' => 'Daily Challenge',
			'nav.titleCollections' => 'Collections',
			'nav.titleMy' => 'My Puzzles',
			'nav.tooltipAchievements' => 'Achievements',
			'nav.tooltipSettings' => 'Settings',
			'settings.title' => 'Settings',
			'settings.playerTitle' => 'Puzzle Player',
			'settings.playerPlayed' => ({required Object time}) => 'Played for ${time}',
			'settings.sectionsAudio' => 'Audio & Haptics',
			'settings.sectionsAppearance' => 'Appearance',
			'settings.sectionsHelp' => 'Help & Guide',
			'settings.sectionsData' => 'Data Management',
			'settings.sectionsLanguage' => 'Language',
			'settings.snapSoundTitle' => 'Snap Sound',
			'settings.snapSoundDesc' => 'Crisp sound when pieces snap together',
			'settings.hapticTitle' => 'Haptic Feedback',
			'settings.hapticDesc' => 'Subtle vibration on snap and interactions',
			'settings.gridPreviewTitle' => 'Grid Preview on Difficulty',
			'settings.gridPreviewDesc' => 'Show jigsaw cut lines on difficulty preview',
			'settings.scatterModeTitle' => 'Scatter Mode',
			'settings.scatterModeDescTray' => 'Pieces kept in bottom tray',
			'settings.scatterModeDescTabletop' => 'Pieces scattered around board',
			'settings.scatterTray' => 'Tray',
			'settings.scatterTabletop' => 'Tabletop',
			'settings.appearanceBgTitle' => 'Background',
			'settings.appearanceBgDesc' => 'Full-screen backdrop during puzzle play',
			'settings.helpTitle' => 'How to Play',
			'settings.helpDesc' => 'Gestures, group drag, ghost, and tools',
			'settings.dataCacheTitle' => 'Thumbnail Cache',
			'settings.dataCacheDesc' => ({required Object size}) => 'Preview cache, currently ${size}',
			'settings.dataClear' => 'Clear',
			'settings.dataViewLogsTitle' => 'View Logs',
			'settings.dataViewLogsDesc' => 'Browse, filter and copy runtime logs',
			'settings.footerVersion' => ({required Object version}) => 'Version ${version}',
			'settings.checkUpdateTitle' => 'Check for Updates',
			'settings.checkUpdateDesc' => ({required Object version}) => 'Current version: ${version}',
			'settings.checkingUpdate' => 'Checking for updates…',
			'settings.alreadyLatest' => 'Already up to date',
			'settings.updateFailed' => 'Failed to check for updates, please try again later',
			'settings.updateDialogTitle' => ({required Object version}) => 'New Version Available ${version}',
			'settings.updateDialogSize' => ({required Object size}) => 'Size: ${size}',
			'settings.updateBtnNow' => 'Update Now',
			'settings.updateBtnLater' => 'Later',
			'settings.updateBtnIgnore' => 'Skip This Version',
			'settings.updateDownloading' => ({required Object percent}) => 'Downloading update… ${percent}%',
			'settings.updateVerifying' => 'Verifying package…',
			'settings.updateInstalling' => 'Starting installation…',
			'settings.updateInstallFailed' => ({required Object error}) => 'Failed to start install: ${error}',
			'settings.toastCacheCleared' => 'Thumbnail cache cleared, will regenerate on next browse',
			'settings.toastCacheClearFailed' => ({required Object error}) => 'Failed to clear cache: ${error}',
			'settings.languageTitle' => 'Language',
			'settings.languageDesc' => 'App display language',
			'settings.languageSystem' => 'Follow System',
			'settings.languageZh' => 'Simplified Chinese',
			'settings.languageEn' => 'English',
			'settings.timeSeconds' => ({required Object count}) => '${count}s',
			'settings.timeMinutes' => ({required Object count}) => '${count} min',
			'settings.timeHoursMinutes' => ({required Object hours, required Object minutes}) => '${hours}h ${minutes}m',
			'home.loadImageFailed' => 'Level image failed to load. Please retry.',
			'home.puzzleTitle' => 'Puzzle',
			'home.emptyCategory' => 'No puzzles found in this category',
			'home.viewAll' => 'View All',
			'home.allCategories' => 'All categories',
			'home.bannerDailyTitle' => ({required Object month, required Object day}) => '${month}/${day} · Today\'s Special',
			'home.bannerDailySub' => 'A fresh daily puzzle to keep your brain sharp',
			'home.bannerDailyBadge' => 'Daily',
			'daily.todayBadge' => 'TODAY',
			'daily.todayFallback' => 'Today\'s Challenge',
			'daily.dateChallenge' => ({required Object month, required Object day}) => '${month}/${day} Challenge',
			'daily.notUnlocked' => '⏳ Not unlocked yet. Please come back later!',
			'daily.dateCaption' => ({required Object month, required Object day}) => '${month}/${day}',
			'daily.todayTitle' => ({required Object month, required Object day}) => '${month}/${day} · Today\'s Challenge',
			'daily.btnClearedReplay' => 'Cleared · Replay',
			'daily.btnResume' => 'Continue',
			'daily.btnStart' => 'Start',
			'daily.totalProgress' => ({required Object done, required Object total}) => 'Daily progress: ${done}/${total}',
			'daily.streakDays' => ({required Object count}) => '${count}-day streak',
			'daily.loadingMonth' => ({required Object month}) => 'Loading ${month} challenges...',
			'daily.loadMonthFailed' => ({required Object month}) => 'Failed to load ${month} challenges. Check your network and retry.',
			'daily.emptyMonth' => ({required Object month}) => 'No levels downloaded for ${month} yet',
			'daily.downloadMonth' => 'Download this month',
			'daily.monthTitle' => ({required Object month, required Object year}) => '${month}/${year}',
			'daily.monthCompleted' => ({required Object done, required Object total}) => 'Completed ${done}/${total}',
			'events.emptyTitle' => 'The fox couldn\'t find any active events',
			'events.emptyHint' => 'Pull to refresh or check back later',
			'events.badgeActive' => 'Live Now',
			'events.badgePast' => 'Past Events',
			'events.badgeZip' => 'Offline Pack',
			'events.badgeOnline' => 'Curated Online',
			'events.descFallback' => 'Featured puzzle challenges',
			'events.subFallback' => 'Limited-time event',
			'events.badgeLimited' => 'Limited-time',
			'events.enter' => 'Start',
			'events.clearTitle' => ({required Object title}) => 'Clear "${title}"',
			'events.clearDesc' => ({required Object size}) => 'Remove downloaded resources for this event?\nIt will free ${size} of disk space. You can re-download at any time.',
			'events.confirmClear' => 'Clear',
			'events.toastCleared' => 'Event storage freed',
			'events.toastClearFailed' => 'Clear failed. Please retry.',
			'events.deleteTooltip' => 'Free event storage',
			'levels.empty' => 'No levels available',
			'levels.titleOf' => ({required Object title, required Object index}) => '${title} · Level ${index}',
			'levels.retryDownload' => 'Retry Download',
			'levels.retryLoad' => 'Retry',
			'levels.countLabel' => ({required Object count}) => '${count} levels',
			'levels.countWithSize' => ({required Object count, required Object size}) => '${count} levels · ${size}',
			'levels.imgLoadFailed' => ({required Object error}) => 'Image load failed: ${error}',
			'levels.networkFail' => 'Level image download failed. Check your network and retry.',
			'collections.toastReady' => ({required Object title}) => '"${title}" is ready to play offline',
			'collections.toastFailed' => 'Download failed. Check your network and retry.',
			'collections.toastError' => ({required Object error}) => 'Download error: ${error}',
			'collections.statsTitle' => 'Featured Collections',
			'collections.statsCount' => ({required Object count}) => '${count} sets',
			'collections.emptyAll' => 'No collections yet',
			'collections.emptyHint' => 'Pull to refresh to sync official content',
			'collections.emptyCollections' => 'No collections',
			'collections.downloading' => ({required Object title, required Object percent}) => '"${title}" is downloading (${percent}%)...',
			'collections.startDownload' => ({required Object title}) => 'Downloading "${title}"...',
			'collections.levelCount' => ({required Object count}) => '${count} levels',
			'collections.badgeDownloaded' => 'Downloaded',
			'collections.badgeDownload' => 'Download',
			'collections.delistedBadge' => 'Delisted',
			'collections.delistedCantDownload' => 'This content is delisted and can\'t be downloaded',
			'collections.freeTooltip' => 'Free collection storage',
			'collections.clearTitle' => ({required Object title}) => 'Clear "${title}"',
			'collections.clearDesc' => ({required Object size}) => 'Remove downloaded resources for this collection?\nIt will free ${size} of disk space. You can re-download at any time.',
			'collections.confirmClear' => 'Clear',
			'collections.toastCleared' => 'Collection storage freed',
			'collections.toastClearFailed' => 'Clear failed. Please retry.',
			'collections.typeOfficial' => 'Official Collection',
			'collections.typeEvent' => 'Limited-time Event',
			'pack.deleteTitle' => ({required Object title}) => 'Delete pack "${title}"',
			'pack.deleteDesc' => ({required Object count, required Object size}) => 'Delete this extension pack?\n${count} levels and ${size} of storage will be removed.',
			'pack.confirmDelete' => 'Delete',
			'pack.toastDeleteFailed' => 'Delete failed. Please retry.',
			'pack.imageMissing' => 'Level image is missing',
			'pack.deleteTooltip' => 'Delete this pack',
			'pack.levelCount' => ({required Object count}) => '${count} Levels',
			'pack.emptyLevels' => 'This pack has no level images',
			'pack.sourceLocal' => 'Gallery / Local',
			'pack.sourceNetwork' => 'Online',
			'unlock.stars3' => ({required Object req, required Object current}) => 'Earn 3 stars on ${req} distinct puzzles (currently ${current}/${req})',
			'unlock.daily' => 'Clear level 1 of the main campaign to unlock the Daily Challenge',
			'unlock.eventPack' => ({required Object req, required Object current}) => 'Clear ${req} main-campaign levels to unlock Events & Packs (currently ${current}/${req})',
			'myPuzzles.actionGallery' => 'From Gallery',
			'myPuzzles.subBatch' => 'Batch import',
			'myPuzzles.actionImportPack' => 'Import Pack',
			'myPuzzles.subZip' => 'ZIP packs',
			'myPuzzles.actionOnline' => 'Search Online',
			'myPuzzles.subOnline' => 'Web gallery',
			'myPuzzles.importedPacksTitle' => 'Imported Packs',
			'myPuzzles.importedPacksCount' => ({required Object count}) => '${count} packs',
			'myPuzzles.customTitle' => 'Custom Puzzles',
			'myPuzzles.emptyTitle' => 'The fox is waiting with an empty basket for your puzzles',
			'myPuzzles.emptyHint' => 'Tap "From Gallery" or "Library" above to get started!',
			'myPuzzles.packBadge' => 'Pack Collection',
			'myPuzzles.packDescFallback' => 'A curated collection of bonus puzzle levels',
			'myPuzzles.packTotalLevels' => ({required Object count}) => '${count} levels total',
			'drawer.title' => 'Library',
			'drawer.count' => ({required Object count}) => '${count} images',
			'drawer.clearAllTitle' => 'Clear Library',
			'drawer.clearAllDesc' => 'Clear all pending material images? (Puzzles already made are not affected.)',
			'drawer.clearAll' => 'Clear All',
			'drawer.emptyTitle' => 'No images in your library yet',
			'drawer.emptyHint' => 'Import local photos via "From Gallery", or download them in "Search Online" — every image lands in your library, ready for puzzle making.',
			'drawer.close' => 'Close',
			'drawer.makePuzzle' => 'Make Puzzle',
			'drawer.deleteImageTooltip' => 'Delete image',
			'drawer.fileMissing' => 'Material file missing or already cleaned',
			'crop.title' => 'Crop & Custom Puzzle',
			'crop.regionLabel' => ({required Object width, required Object height}) => 'Crop area: ${width} × ${height}',
			'crop.gestureHint' => 'Drag to move the crop area · pinch or scroll to zoom',
			'crop.saving' => 'Saving...',
			'crop.saveButton' => 'Save Custom Level',
			'crop.optimizing' => 'Optimizing image quality and creating your custom puzzle...',
			'crop.saveFailedToast' => ({required Object error}) => 'Save failed: ${error}',
			'crop.decodeFailedToast' => 'Image decode failed, please pick another image',
			'online.savedBanner' => ({required Object width, required Object height}) => 'Saved to library (${width}×${height})',
			'online.savedSourceSub' => 'From web · Tap to view',
			'online.alreadyInBox' => 'This image is already in your download box',
			'online.downloadFailed' => ({required Object error}) => 'Download failed: ${error}',
			'online.noHighResDetected' => 'No high-res image detected on this page. Open the photo detail page and try again.',
			'online.closePickerTooltip' => 'Close online search',
			'online.backTooltip' => 'Back',
			'online.refreshTooltip' => 'Refresh',
			'online.extracting' => 'Extracting...',
			'online.extractCurrent' => 'Extract this page\'s image',
			'online.dismissTooltip' => 'Dismiss',
			'share.title' => 'Share Result',
			'share.exportTooltip' => 'Export',
			'share.toastSaved' => 'Share card saved to temp folder',
			'share.toastExportFailed' => ({required Object error}) => 'Export failed: ${error}',
			'share.completed' => 'Puzzle Complete!',
			'share.timeLabel' => 'Time',
			'share.piecesLabel' => 'Pieces',
			'share.stepsLabel' => 'Moves',
			'share.exporting' => 'Exporting...',
			'share.saveButton' => 'Save Share Card',
			'importPack.pickFailed' => ({required Object error}) => 'File selection failed: ${error}',
			'importPack.hintPickFile' => 'Pick a local ZIP file or enter a download URL',
			'importPack.extractingLocal' => 'Extracting & parsing local pack...',
			'importPack.downloadingNet' => 'Downloading & extracting network pack...',
			'importPack.imported' => ({required Object title, required Object count}) => 'Imported "${title}" (${count} levels)',
			'importPack.importFailedToast' => ({required Object error}) => 'Import failed: ${error}',
			'importPack.appbarTitle' => 'Import Extension Pack (.zip)',
			'importPack.infoBanner' => 'Any ZIP containing JPG/PNG/WebP images can be imported; it becomes its own collection that you can delete anytime.',
			'importPack.methodLocal' => 'Method 1: Choose a local file',
			'importPack.browseHint' => 'Tap the button on the right to pick a .zip file',
			'importPack.browse' => 'Browse...',
			'importPack.methodNetwork' => 'Method 2: Enter a download URL',
			'importPack.startImport' => 'Start Import',
			'background.title' => 'Change Puzzle Background',
			'background.tableLabel' => ({required Object index}) => 'Table ${index}',
			'background.colorLabels.0' => 'Warm Oatmeal',
			'background.colorLabels.1' => 'Misty Gray',
			'background.colorLabels.2' => 'Sage Green',
			'background.colorLabels.3' => 'Misty Blue',
			'background.colorLabels.4' => 'Dusty Mauve',
			'background.colorLabels.5' => 'Dark Slate',
			'howTo.title' => 'How to Play',
			'howTo.welcomeTitle' => 'Get Started with Jigsaw Puzzles',
			'howTo.welcomeSub' => 'Master these core gestures and helper tools, and you will breeze through even the hardest puzzles!',
			'howTo.t1.title' => 'Drag & Snap',
			'howTo.t1.page' => 'Drag a piece with one finger near its correct spot; it snaps into place with a crisp click.',
			'howTo.t2.title' => 'Group Merge (Cluster)',
			'howTo.t2.page' => 'Connected pieces can be joined anywhere on the tray or canvas, even before reaching their correct cells, then moved as a group.',
			'howTo.t3.title' => 'Pinch to Zoom & Pan',
			'howTo.t3.page' => 'Pinch to zoom the board seamlessly; two-finger drag or middle-mouse drag pans the canvas, making it easy to align fine details.',
			'howTo.t4.title' => 'Ghost Guide Overlay',
			'howTo.t4.page' => 'Tap the ghost icon in the top bar to overlay a 20%/45% translucent image, helping you spot lines and colors to place pieces faster.',
			'howTo.t5.title' => 'Edge Pieces Filter',
			'howTo.t5.page' => 'Tap the edge filter icon to highlight flat outer pieces and dim inner ones, so you can build the frame first.',
			'howTo.t6.title' => 'Organize Tray',
			'howTo.t6.page' => 'Scattered single pieces on the board can be tidied into the tray instantly with the broom icon, restoring a clean view.',
			'logs.title' => 'Runtime Logs',
			'logs.filterPrefix' => 'Filter: ',
			'logs.filterAll' => 'All',
			'logs.scrollTopTooltip' => 'Back to top (newest)',
			'logs.copyTooltip' => 'Copy logs',
			'logs.copyFiltered' => ({required Object count}) => 'Copy current view (${count})',
			'logs.copyAll' => ({required Object count}) => 'Copy all logs (${count})',
			'logs.nothingToCopy' => 'No logs to copy',
			'logs.copiedFiltered' => ({required Object count}) => 'Copied ${count} logs from current view',
			'logs.copiedAll' => ({required Object count}) => 'Copied all ${count} logs',
			'logs.clearTooltip' => 'Clear logs',
			'logs.clearConfirmTitle' => 'Clear all logs?',
			'logs.clearConfirmDesc' => 'Deletes log files on disk and clears the in-memory records. This cannot be undone.\nLogging restarts from scratch, so future copies will be much smaller.',
			'logs.clearConfirmBtn' => 'Clear logs',
			'logs.clearedToast' => 'Logs cleared, recording restarted from scratch',
			'logs.emptyFiltered' => 'No logs under the current filter',
			'logs.loading' => 'Loading logs...',
			'logs.close' => 'Close',
			'source.main' => 'Main',
			'source.daily' => 'Daily',
			'source.custom' => 'Custom',
			'source.pack' => 'Pack',
			'source.album' => 'Gallery',
			'source.online' => 'Online',
			'source.preset' => 'Official',
			'source.official' => 'Official Collection',
			'source.event' => 'Limited-time',
			'downloads.q4k' => '4K Ultra HD',
			'downloads.q2k' => '2K QHD',
			'downloads.q1080' => 'FHD 1080p',
			'downloads.q720' => 'HD 720p',
			'downloads.qsd' => 'SD',
			'achievements.first_win.title' => 'First Win',
			'achievements.first_win.desc' => 'Complete your first puzzle',
			'achievements.win_10.title' => 'Practice Makes Perfect',
			'achievements.win_10.desc' => 'Complete 10 puzzles',
			'achievements.win_50.title' => 'Puzzle Expert',
			'achievements.win_50.desc' => 'Complete 50 puzzles',
			'achievements.win_100.title' => 'Puzzle Master',
			'achievements.win_100.desc' => 'Complete 100 puzzles',
			'achievements.star_1.title' => 'Three-Star Debut',
			'achievements.star_1.desc' => 'Earn your first 3-star rating',
			'achievements.star_10.title' => 'Shining Star',
			'achievements.star_10.desc' => 'Earn 10 three-star ratings',
			'achievements.star_30.title' => 'Starry Sky',
			'achievements.star_30.desc' => 'Earn 30 three-star ratings',
			'achievements.star_50.title' => 'Star Lord',
			'achievements.star_50.desc' => 'Earn 50 three-star ratings',
			'achievements.tier_l3.title' => 'Intermediate Challenge',
			'achievements.tier_l3.desc' => 'Complete a Medium (L3) or higher puzzle',
			'achievements.tier_l4.title' => 'Advanced Expert',
			'achievements.tier_l4.desc' => 'Complete a Hard (L4) or higher puzzle',
			'achievements.tier_l5.title' => 'Conqueror',
			'achievements.tier_l5.desc' => 'Complete an Expert (L5) or higher puzzle',
			'achievements.tier_l6.title' => 'Ultimate Summit',
			'achievements.tier_l6.desc' => 'Complete a Master (L6) puzzle',
			'achievements.custom_1.title' => 'Creator',
			'achievements.custom_1.desc' => 'Complete 1 custom puzzle',
			'achievements.custom_5.title' => 'Boundless Creativity',
			'achievements.custom_5.desc' => 'Complete 5 custom puzzles',
			'achievements.no_hint_win.title' => 'Dexterous',
			'achievements.no_hint_win.desc' => 'Complete a puzzle without hints',
			'achievements.speed_10min.title' => 'Speedster',
			'achievements.speed_10min.desc' => 'Complete a 100+ piece puzzle within 10 minutes',
			'achievements.night_owl.title' => 'Night Owl',
			'achievements.night_owl.desc' => 'Complete a puzzle between 22:00 - 05:00',
			'achievements.snap_100.title' => 'First Touch',
			'achievements.snap_100.desc' => 'Snap 100 pieces',
			'achievements.snap_500.title' => 'Getting Better',
			'achievements.snap_500.desc' => 'Snap 500 pieces',
			'achievements.snap_2000.title' => 'Tempered',
			'achievements.snap_2000.desc' => 'Snap 2000 pieces',
			'achievements.time_30m.title' => 'Immersed',
			'achievements.time_30m.desc' => 'Play for 30 minutes total',
			'achievements.time_2h.title' => 'Puzzle Enthusiast',
			'achievements.time_2h.desc' => 'Play for 2 hours total',
			'achievements.time_10h.title' => 'Time Flies',
			'achievements.time_10h.desc' => 'Play for 10 hours total',
			'achievements.daily_7.title' => 'Daily Dedication',
			'achievements.daily_7.desc' => 'Complete 7 daily challenges',
			'achievements.master_all.title' => 'Puzzle Grandmaster',
			'achievements.master_all.desc' => 'Achieve all 24 achievements',
			'difficulty.tier.l1' => 'Novice Easy',
			'difficulty.tier.l1_5' => 'Beginner+',
			'difficulty.tier.l2' => 'Beginner',
			'difficulty.tier.l3' => 'Medium',
			'difficulty.tier.l4' => 'Hard',
			'difficulty.tier.l5' => 'Expert',
			'difficulty.tier.l6' => 'Master',
			'difficulty.tier.l7' => 'Grandmaster',
			'difficulty.estimated.l1' => '1-3 min',
			'difficulty.estimated.l1_5' => '2-4 min',
			'difficulty.estimated.l2' => '5-8 min',
			'difficulty.estimated.l3' => '12-18 min',
			'difficulty.estimated.l4' => '25-35 min',
			'difficulty.estimated.l5' => '50-75 min',
			'difficulty.estimated.l6' => '1.5-3 hrs',
			'difficulty.estimated.l7' => '3-5 hrs',
			'difficulty.aspect.square' => '1:1 Square',
			'difficulty.aspect.portrait2x3' => '2:3 Portrait',
			'difficulty.aspect.landscape3x2' => '3:2 Landscape',
			'difficulty.aspect.portrait3x4' => '3:4 Portrait',
			'difficulty.aspect.landscape4x3' => '4:3 Landscape',
			'difficulty.pieceCount' => ({required Object cols, required Object rows, required Object count}) => '${cols} x ${rows} (${count} pieces)',
			'difficulty.recommended' => 'Recommended',
			'game.titleLevel' => ({required Object index}) => 'Level ${index}',
			'game.titleDaily' => ({required Object date}) => '${date} Daily',
			'game.titleCustom' => 'Custom Puzzle',
			'game.titlePack' => ({required Object title}) => '${title}',
			'game.tooltipBack' => 'Back',
			'game.tooltipEdges' => 'Edge pieces only',
			'game.tooltipEdgesAll' => 'Show all pieces',
			'game.tooltipHint' => 'Hint',
			'game.tooltipGhost' => ({required Object opacity}) => 'Ghost ${opacity}%',
			'game.tooltipGhostOff' => 'Ghost off',
			'game.tooltipPreview' => 'Preview',
			'game.tooltipOrganize' => 'Organize tray',
			'game.tooltipChangeBg' => 'Change background',
			'game.hintNotEnoughCoins' => ({required Object price, required Object coins}) => 'Not enough coins (need ${price}, you have ${coins})',
			'game.imageDecodeFailed' => 'Image decode failed, please retry',
			'game.tapToReturn' => 'Tap anywhere to return',
			'game.zoomReset' => 'Reset',
			'game.progress' => ({required Object percent}) => '${percent}%',
			'victory.title' => 'Puzzle Complete!',
			'victory.stars' => ({required num count}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(count, one: '1 Star', other: '${count} Stars', ), 
			'victory.time' => ({required Object time}) => 'Time: ${time}',
			'victory.pieces' => ({required Object count}) => '${count} pieces',
			'victory.coinsReward' => ({required Object coins}) => '+${coins} coins',
			'victory.newAchievements' => ({required Object count}) => '${count} new achievements',
			'victory.btnNext' => 'Next Level',
			'victory.btnShare' => 'Share',
			'victory.btnView' => 'View Puzzle',
			'victory.btnExit' => 'Exit',
			'victory.btnSaveWallpaper' => 'Save Wallpaper',
			'victory.perfect' => 'Perfect!',
			'victory.great' => 'Great!',
			'victory.btnClose' => 'Close (Esc)',
			'victory.toastWallpaperSaved' => 'Wallpaper saved to local folder',
			'victory.toastSaveWallpaperFailed' => ({required Object error}) => 'Failed to save wallpaper: ${error}',
			'continueDialog.progressLabel' => 'Progress',
			'continueDialog.timeLabel' => 'Time Spent',
			'continueDialog.spec' => ({required Object key}) => 'Spec: ${key}',
			'continueDialog.specPieces' => ({required Object key, required Object count}) => 'Spec: ${key} (${count} pieces)',
			'continueDialog.piecesCount' => ({required Object count}) => 'Pieces ${count}',
			'continueDialog.foxHint' => 'The little fox is waiting for you to finish this puzzle!',
			'continueDialog.restartTitle' => 'Restart this puzzle?',
			'continueDialog.restartDesc' => 'This will clear the saved progress for this difficulty. It cannot be undone. Restart now?',
			'continueDialog.btnRestart' => 'Restart',
			'continueDialog.restartConfirm' => 'Yes, Restart',
			'continueDialog.btnResume' => 'Keep Going',
			'chooseDifficulty.title' => 'Choose Difficulty',
			'chooseDifficulty.pieces' => ({required Object count}) => '${count} pieces',
			'chooseDifficulty.recommended' => 'Recommended',
			'chooseDifficulty.locked' => 'Locked',
			'chooseDifficulty.lockedByLevel' => 'Level locked',
			'chooseDifficulty.lockedDesc' => 'Complete previous level to unlock',
			'chooseDifficulty.btnStart' => 'Start',
			'chooseDifficulty.btnReplay' => 'Replay',
			'chooseDifficulty.btnContinue' => ({required Object percent}) => 'Continue (${percent}%)',
			'chooseDifficulty.btnReset' => 'Reset progress',
			'chooseDifficulty.savedProgress' => ({required Object percent}) => 'Saved progress ${percent}% detected',
			'chooseDifficulty.previewHint' => 'Preview with cut lines',
			'chooseDifficulty.badgeCleared' => 'Cleared',
			'chooseDifficulty.deleteTitle' => 'Delete Custom Puzzle',
			'chooseDifficulty.deleteDesc' => ({required Object title}) => 'Delete "${title}" permanently? This cannot be undone.',
			'chooseDifficulty.deleteDescGeneric' => 'Delete this custom puzzle permanently? This cannot be undone.',
			'chooseDifficulty.deleteConfirm' => 'Delete',
			'chooseDifficulty.deleteTooltip' => 'Delete this custom puzzle',
			'chooseDifficulty.favAdd' => 'Add to favorites',
			'chooseDifficulty.favRemove' => 'Remove from favorites',
			'chooseDifficulty.lockedProgress' => ({required Object gap, required Object tier}) => 'Earn ${gap} more 3-star puzzles to unlock ${tier}',
			'achievementsPage.title' => 'Achievements',
			'achievementsPage.stats' => 'Stats',
			'achievementsPage.groupClears' => 'Clears & Stars',
			'achievementsPage.groupAssets' => 'Journey & Assets',
			'achievementsPage.totalStars' => 'Total Stars',
			'achievementsPage.totalSolved' => 'Solved',
			'achievementsPage.totalSnaps' => 'Snaps',
			'achievementsPage.totalTime' => 'Play Time',
			'achievementsPage.threeStarCount' => '3-Star Clears',
			'achievementsPage.coinsOwned' => 'Coins',
			'achievementsPage.wall' => 'Achievement Wall',
			'achievementsPage.wallCount' => ({required Object count}) => '${count} achievements total',
			'achievementsPage.unlocked' => 'Unlocked',
			'achievementsPage.locked' => 'Locked',
			'achievementsPage.claim' => 'Claim',
			'achievementsPage.claimed' => 'Claimed',
			'achievementsPage.claimedReward' => ({required Object reward}) => 'Claimed: ${reward}',
			'achievementsPage.claimFailed' => 'Failed to claim reward, please try again',
			'achievementsPage.coins' => ({required Object count}) => '${count} coins',
			'myCenter.tabs.inProgress' => ({required Object count}) => 'Active (${count})',
			'myCenter.tabs.favorites' => ({required Object count}) => 'Saved (${count})',
			'myCenter.tabs.completed' => ({required Object count}) => 'Done (${count})',
			'myCenter.tabs.custom' => ({required Object count}) => 'Custom (${count})',
			'myCenter.topActions.gallery' => 'Gallery',
			'myCenter.topActions.gallerySub' => 'Custom',
			'myCenter.topActions.online' => 'Online',
			'myCenter.topActions.onlineSub' => 'Search',
			'myCenter.topActions.archive' => 'Archive',
			'myCenter.topActions.archiveSub' => ({required Object count}) => '${count} images',
			'myCenter.topActions.import' => 'Import',
			'myCenter.topActions.importSub' => 'ZIP',
			'myCenter.empty.inProgressTitle' => 'No puzzles in progress',
			'myCenter.empty.inProgressSub' => 'Pick a puzzle and start!',
			'myCenter.empty.favoritesTitle' => 'No favorites yet',
			'myCenter.empty.favoritesSub' => 'Tap heart in difficulty sheet to favorite',
			'myCenter.empty.completedTitle' => 'No completed puzzles yet',
			'myCenter.empty.completedSub' => 'Complete any puzzle to see it here!',
			'myCenter.empty.customTitle' => 'No custom puzzles',
			'myCenter.empty.customSub' => 'Use Gallery to create your own!',
			'myCenter.empty.goExplore' => 'Explore',
			'myCenter.empty.create' => 'Create from Gallery',
			'myCenter.card.orphan' => 'Expired',
			'myCenter.card.orphanDesc' => 'Tap to clean',
			'myCenter.card.progress' => ({required Object percent}) => '${percent}%',
			'myCenter.card.retry' => 'Retry',
			'myCenter.orphanDialog.title' => 'Puzzle source unavailable',
			'myCenter.orphanDialog.desc' => ({required Object title}) => 'This record\'s puzzle image is currently unavailable, but the record can stay.\nRemove "${title}" from your records and favorites only? Downloaded images are not affected.',
			'myCenter.orphanDialog.keep' => 'Keep it',
			'myCenter.orphanDialog.remove' => 'Remove',
			'myCenter.toast.importSuccess' => ({required Object count}) => 'Imported ${count} images to your library',
			'myCenter.toast.importFailed' => ({required Object error}) => 'Failed to pick images: ${error}',
			'myCenter.toast.webviewMissing' => 'WebView2 runtime is not installed; online image search is unavailable.',
			'myCenter.toast.imageNotFound' => 'Image unavailable — this record can\'t be played yet',
			'myCenter.toast.imageNotReady' => 'Image not ready. Reconnect and retry.',
			'myCenter.toast.openFailed' => 'Failed to open. Please retry.',
			'boot.initTitle' => 'Initializing game content…',
			'boot.initSubtitle' => 'First launch downloads the puzzle library over the network.',
			'boot.failedTitle' => 'Initialization failed',
			'boot.failedDesc' => 'Cannot reach the content server. Check your network and retry.',
			'boot.retry' => 'Retry',
			_ => null,
		};
	}
}
