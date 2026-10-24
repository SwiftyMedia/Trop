# Contributing to Trop

Thank you for your interest in contributing to Trop! Please follow these guidelines for translations and code contributions.

---

## Contributing Translations

Trop keeps its translations in JSON files inside the `languages/` directory.
The English source is `languages/en.json`. Each additional language uses its locale as the filename, for example:

```text
languages/
├── en.json
├── zh.json
```

### Add or Update a Language

1. Copy `languages/en.json` to a new file, such as `languages/es.json`.
2. Keep every JSON key (the left side) completely unchanged.
3. Translate the string values (the right side) while preserving any format placeholders (such as `%@` or `%d`).
4. Run the generator script:
```bash
python3 scripts/generate_localizations.py
```


5. Include both your new JSON file and the generated `Trop/Resources/<locale>.lproj/Localizable.strings` file in your pull request.

The generator uses English as a fallback for keys that have not been translated yet and checks that translations do not introduce unknown keys. If you are adding brand-new English strings, add them to `languages/en.json` first.

### Handling YouTube Music & Dynamic Server Strings

YouTube Music occasionally sends section titles, headers, or metadata directly from their servers (e.g., `"Singles & EPs"`, `"Trending songs for you"`, `"Covers and remixes"`), regardless of the user's app language settings.

To ensure seamless localization:

* **Translate Server Keys:** `languages/en.json` includes common server-side English strings so they can be mapped and localized properly in your language file.
* **Handling Edge Cases:** Because YouTube Music occasionally updates, introduces variations, or sends new response strings dynamically, some untranslated English strings may still appear. Feel free to add any new server strings to `languages/en.json` and your language file.

Please open a pull request with the language name and locale in the title (e.g., `feat(localization): add Spanish translation`).

---

## Code Guidelines & Standards

### Naming & Conventions

* **Types:** Use `PascalCase`.
* **Variables & Functions:** Use `camelCase`.
* **Booleans:** Prefix with `is`, `has`, or `show`.
* **Access Control:** Avoid `public` unless strictly necessary.

### Safety & Error Handling

* **No Force Unwraps:** Avoid using `!`.
* **Retain Cycles:** Always use `[weak self]` in closures.
* **Errors:** Log errors via `Log.<category>.error()`. Do not leave empty `catch {}` blocks.

### SwiftUI & View Patterns

* **State:** Use `@Observable` instead of `ObservableObject`.
* **Async Loading:** Use `.task { }` instead of `.onAppear`.
* **Rows:** Add `.contentShape(Rectangle())` to make entire rows tappable, and use `.buttonStyle(.plain)`.
* **Decomposition:** Extract complex subviews into `private var` computed properties.
