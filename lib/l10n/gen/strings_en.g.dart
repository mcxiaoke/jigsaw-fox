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

	/// en: 'Initial Scatter Mode'
	String get scatterModeTitle => 'Initial Scatter Mode';

	/// en: 'Tray (default, phone-friendly)'
	String get scatterModeDescTray => 'Tray (default, phone-friendly)';

	/// en: 'Tabletop scatter (wide screens)'
	String get scatterModeDescTabletop => 'Tabletop scatter (wide screens)';

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

	/// en: 'Reset All Data'
	String get dataResetTitle => 'Reset All Data';

	/// en: 'Clear all progress, daily and custom puzzles'
	String get dataResetDesc => 'Clear all progress, daily and custom puzzles';

	/// en: 'Reset all data?'
	String get dataResetConfirmTitle => 'Reset all data?';

	/// en: 'This cannot be undone. All main progress, daily challenges and custom puzzles will be cleared.'
	String get dataResetConfirmDesc => 'This cannot be undone. All main progress, daily challenges and custom puzzles will be cleared.';

	/// en: 'Cancel'
	String get dataCancel => 'Cancel';

	/// en: 'Reset'
	String get dataConfirmReset => 'Reset';

	/// en: 'Version {version}'
	String footerVersion({required Object version}) => 'Version ${version}';

	/// en: 'Thumbnail cache cleared, will regenerate on next browse'
	String get toastCacheCleared => 'Thumbnail cache cleared, will regenerate on next browse';

	/// en: 'Failed to clear cache: {error}'
	String toastCacheClearFailed({required Object error}) => 'Failed to clear cache: ${error}';

	/// en: 'All game data has been reset'
	String get toastDataReset => 'All game data has been reset';

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
			'settings.scatterModeTitle' => 'Initial Scatter Mode',
			'settings.scatterModeDescTray' => 'Tray (default, phone-friendly)',
			'settings.scatterModeDescTabletop' => 'Tabletop scatter (wide screens)',
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
			'settings.dataResetTitle' => 'Reset All Data',
			'settings.dataResetDesc' => 'Clear all progress, daily and custom puzzles',
			'settings.dataResetConfirmTitle' => 'Reset all data?',
			'settings.dataResetConfirmDesc' => 'This cannot be undone. All main progress, daily challenges and custom puzzles will be cleared.',
			'settings.dataCancel' => 'Cancel',
			'settings.dataConfirmReset' => 'Reset',
			'settings.footerVersion' => ({required Object version}) => 'Version ${version}',
			'settings.toastCacheCleared' => 'Thumbnail cache cleared, will regenerate on next browse',
			'settings.toastCacheClearFailed' => ({required Object error}) => 'Failed to clear cache: ${error}',
			'settings.toastDataReset' => 'All game data has been reset',
			'settings.languageTitle' => 'Language',
			'settings.languageDesc' => 'App display language',
			'settings.languageSystem' => 'Follow System',
			'settings.languageZh' => 'Simplified Chinese',
			'settings.languageEn' => 'English',
			'settings.timeSeconds' => ({required Object count}) => '${count}s',
			'settings.timeMinutes' => ({required Object count}) => '${count} min',
			'settings.timeHoursMinutes' => ({required Object hours, required Object minutes}) => '${hours}h ${minutes}m',
			_ => null,
		};
	}
}
