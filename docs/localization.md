# Localisation

RunPlay Studio ships in English (the development language), Simplified Chinese
(`zh-Hans`, mainland conventions) and Traditional Chinese (`zh-Hant`, Taiwan
conventions). This page is the reference for how strings, formats, and exports
are localised. `scripts/check-localization.sh`, the tests listed below, and CI
are the executable truth.

## Where strings live

Each Swift module owns one String Catalog, compiled into that module's resource
bundle:

| Module | Catalog | Helper for strings built in Swift |
|---|---|---|
| RunPlayCore | `RunPlayCore/Localization/Localizable.xcstrings` | `coreLocalized("…")` |
| RunPlayPlatform | `RunPlayPlatform/Localization/Localizable.xcstrings` | `platformLocalized("…")` |
| RunPlayStudio | `RunPlayStudio/Localization/Localizable.xcstrings` | `studioLocalized("…")` |

- The helpers take a `String.LocalizationValue` whose English text is the key,
  and read the module's own bundle — never the host's main bundle — so the app,
  `swift run`, and tests resolve the same tables. An optional `locale:` pins a
  language (the PNG card, the video HUD, and tests); it costs tens of
  microseconds per call, so render paths resolve once and reuse the text.
- SwiftUI literals (`Text("Overview")`, `Button`, `Label`, `.help`,
  `.accessibilityLabel`, `TableColumn`, `.value(…)` in Charts) are
  `LocalizedStringKey`s that SwiftUI resolves against the **main** bundle, so the
  packaged app also carries Studio's compiled tables in
  `Contents/Resources/<language>.lproj` (see Packaging).
- Core's catalog is a macOS-only resource: Linux has no `xcstringstool`, so on
  Linux the catalog sits outside the target, `coreLocalized` returns the English
  key, and no resource bundle is built. Count-bearing keys therefore read in
  their plural English form on Linux ("1 runs"); tests that assert a singular
  form say so and stay platform-neutral.

## Writing a localisable string

- Wrap the whole sentence in one call with interpolations, so a translator can
  reorder it. Never build a sentence from `+`-joined fragments or splice a word
  chosen in code into an English literal.
- Interpolate only `String` and integer values. A `Double` becomes `%lf` and
  prints six decimals: format numbers and units first with `DisplayFormatter`,
  then interpolate the text.
- Counts: write the plural English form and interpolate the integer
  (`studioLocalized("\(count) runs")`). The catalog's `en` entry carries the
  singular as a plural variant, or as a substitution (`%#@runs@`) when the string
  has several arguments. Chinese has no plural forms and translates the sentence
  once with a measure word (`%lld 次跑步`).
- Enum raw values and other persisted strings never change. When a raw value
  doubled as display text, the type has a display property (`message`,
  `displayName`) that switches over its cases.
- When one English word needs two translations, give the rarer meaning a
  semantic key with an English default and a translator comment:
  `String(localized: "compare.delta.paused_time", defaultValue: "Paused",
  bundle: .module, comment: "…")`. The module helpers cannot carry semantic
  keys: the compiler would extract the default value as the key. In use today:
  `*.paused_time` (a duration, not the paused state), `*.elevation_gain` (gain,
  not altitude), `comparison.column.selected_run`, and the `route_group.*` keys.

## Deliberately not translated

- **Machine-readable exports.** CSV column headers, CSV section comments, CSV
  numbers (`DisplayFormatter.formatNumber`), and JSON keys and values form a
  stable schema in every language. The JSON export writes analysis warnings by
  their English raw value.
- **Persisted text.** Detected segment highlights store their English
  `canonicalTitle` and a POSIX-formatted subtitle (also the segments CSV
  "Title" column); `SegmentHighlight.displayTitle()` / `displaySubtitle()`
  rebuild the text in the app's language from the stored type, pace, and climb.
  Workout names generated at import ("Imported Run", multi-session FIT names)
  and route-group derived names are stored in the language active at import or
  derivation, like any default name the user can edit.
- **Identifiers and vocabularies.** Unit tokens (`"km"`, `"s/km"`, `"bpm"`) that
  metric code matches on (shown through `DisplayFormatter.unitSymbol(forToken:)`),
  parser vocabularies (GPX/TCX/FIT names, Strava CSV columns and activity types),
  search tokens, logs, and developer diagnostics.
- **Names and marks.** RunPlay Studio, Strava, Garmin, file formats, DEM,
  TRIMP, and the map and video marker letters S, F, P, and C.

## Formats

- **Numbers and units:** `DisplayFormatter` formats display values with
  Foundation measurement and number styles in the current (or a pinned) locale:
  "5.00 km" is "5.00公里" in Simplified Chinese, metres are 米 in zh-Hans and 公尺
  in zh-Hant (Taiwan), "5,00 km" in German. Pace is the locale-neutral M:SS plus
  `perKilometerSuffix()` ("5:30 /公里"). Beats and steps per minute, which
  Foundation does not model, come from Core's catalog (次/分, 步/分). Values round
  half away from zero ("10.05 km" shows "10.1 km"). On Linux the formatters keep
  their fixed English output.
- **Dates and times:** dates use `DateFormatter` styles or templates, never fixed
  patterns, so the locale orders the fields and the time of day follows the
  locale's and the user's 12/24-hour setting ("14:30" in zh_CN, "下午2:30" in
  zh_TW unless 24-hour time is on). Trends period labels use the `yMMMd`,
  `yMMM`, and `y` templates. Persisted or machine names keep fixed ISO-style
  formats (export file names, FIT session candidate names).
- **Week start:** weekly Trends buckets follow `WorkoutTrendsWeekConvention`,
  read from the user's calendar — the locale's week data, or the first weekday
  chosen in System Settings. Core defaults to ISO 8601 (Monday).

## Exports

- **PNG summary card:** `ExportSummaryCardModel(…, locale:timeZone:)` and
  `ExportSummaryCardPresentation.locale` resolve every string in one language;
  `ExportSummaryCardLabels` holds the card's fixed labels. The card is typeset
  in its language (`.typesettingLanguage`), which selects the Simplified or
  Traditional Chinese font for Han characters — SwiftUI's `\.locale` alone does
  not. The split table is a `Grid` sized to its content, and tile labels scale
  down rather than truncate.
- **MP4 replay HUD:** `VideoHUDText` tags every string with the export's
  language (`kCTLanguageAttributeName`, the CoreText equivalent), measures label
  columns with the real font instead of fixed Latin widths, and ends overlong
  lines with an ellipsis instead of clipping mid-glyph.

## Packaging and language selection

The app declares `CFBundleLocalizations` (`en`, `zh-Hans`, `zh-Hant`), carries the
Core, Platform, and Studio resource bundles, and copies Studio's compiled tables
into `Contents/Resources` (`scripts/assemble-app-bundle.sh`;
`scripts/verify-app-bundle.sh` checks all of it). Module bundles follow the
main bundle's language, so a bundle without `CFBundleLocalizations` stays
English: `swift run RunPlayStudio` is always English. To run in Chinese, use the
packaged app and set the language per app in System Settings → General →
Language & Region → Applications, or launch it once with
`-AppleLanguages '(zh-Hans)'` (see `docs/manual-testing.md`).

## Checking catalogs

```bash
./scripts/check-localization.sh            # check: fails on any problem
./scripts/check-localization.sh --update   # sync: add new keys, drop stale ones
```

The script builds the product targets with `-emit-localized-strings` in its own
scratch path (`.build-localization`), syncs a copy of each catalog with
`xcrun xcstringstool sync` (the same merge Xcode performs), and fails on keys
missing from a catalog, stale keys no longer in source, and live keys without a
translated `zh-Hans` and `zh-Hant` value whose format specifiers match the
English. CI runs it on the macOS release-compile leg and in the release lane.

To change a string: edit the code, run `--update`, translate the new keys in
Xcode's String Catalog editor (or the JSON), and rerun the check.

## Tests

- `CatalogResolutionTests` (Core, Platform, Studio): every catalog key resolves
  in English, Simplified, and Traditional Chinese through the compiled tables,
  and plural variants pick the right form.
- `ExportSummaryCardLocalizationTests`: summary-card snapshots in en, zh-Hans,
  and zh-Hant from a synthetic run, plus structural checks (no untranslated
  words, the locale's clock) and a typesetting check: the card renders
  byte-identically whatever typesetting language surrounds it, so Traditional
  text keeps Traditional glyph shapes. Snapshots catch a card in the wrong
  language or script, but glyph shapes alone stay under their tolerance.
  References live in
  `RunPlayStudio/Tests/Snapshots/`; after an intended visual change, rerun with
  `RUNPLAY_RECORD_SNAPSHOTS=1` and review the PNGs before committing them. A
  failing snapshot writes its actual render and a diff image to
  `RUNPLAY_SNAPSHOT_FAILURES_DIR` (default: a folder in the temporary
  directory); CI uploads them as a `snapshot-failures-*` artifact.
- `VideoHUDLocalizationTests`, `LocalizedDisplayFormatterTests`,
  `SegmentHighlightLocalizationTests`, `WorkoutTrendsWeekConventionTests`.

## Terminology

| English | zh-Hans | zh-Hant |
|---|---|---|
| Pace / Active Pace | 配速 / 运动配速 | 配速 / 運動配速 |
| Heart rate | 心率 | 心率 |
| Cadence | 步频 | 步頻 |
| Elevation (altitude) / gain | 海拔 / 爬升 | 海拔 / 爬升 |
| Split / Lap | 分段 / 圈 | 分段 / 圈 |
| Segment (route stretch) | 路段 | 路段 |
| Personal record | 个人纪录 | 個人紀錄 |
| Elapsed / Active / Moving time | 总用时 / 运动时间 / 移动时间 | 總用時 / 運動時間 / 移動時間 |
| Route / Loop | 路线 / 环线 | 路線 / 環線 |
| Training load / Fitness / Fatigue / Form | 训练负荷 / 体能 / 疲劳 / 状态 | 訓練負荷 / 體能 / 疲勞 / 狀態 |
| Import / Export | 导入 / 导出 | 匯入 / 匯出 |
