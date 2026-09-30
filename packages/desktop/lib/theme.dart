import 'dart:io';

import 'package:flutter/material.dart';

import 'design_tokens.dart';

/// Native controls consume the same semantic roles as the web workspace.
/// No seeded Material palette is allowed to invent additional brand colors.
class ListenboxTheme {
  const ListenboxTheme(this.dark);
  final bool dark;
  String get fontFamily => Platform.isMacOS
      ? '.SF NS Text'
      : Platform.isWindows
      ? 'Segoe UI'
      : 'sans-serif';
  Color get background => dark ? DesignTokens.darkBg : DesignTokens.bg;
  Color get rail => dark ? DesignTokens.darkRail : DesignTokens.rail;
  Color get sheet => dark ? DesignTokens.darkSheet : DesignTokens.sheet;
  Color get ink => dark ? DesignTokens.darkInk : DesignTokens.ink;
  Color get muted => dark ? DesignTokens.darkMuted : DesignTokens.muted;
  Color get border =>
      dark ? DesignTokens.darkBorder : DesignTokens.borderStrong;
  Color get divider => dark ? DesignTokens.darkDivider : DesignTokens.divider;
  Color get selected =>
      dark ? DesignTokens.darkNavigationActive : DesignTokens.navigationActive;
  Color get action => dark ? DesignTokens.darkPrimary : DesignTokens.primary;
  Color get onAction => DesignTokens.sheet;
  Color get hover =>
      dark ? DesignTokens.darkPrimaryHover : DesignTokens.primaryHover;
  Color get focus => dark ? DesignTokens.darkFocus : DesignTokens.focus;
  Color get danger =>
      dark ? DesignTokens.dangerSoft : DesignTokens.dangerStrong;
  TextStyle get pageTitle => DesignTokens.pageTitleType.copyWith(color: ink);
  TextStyle get title => DesignTokens.titleType.copyWith(color: ink);
  TextStyle get label => DesignTokens.labelType.copyWith(color: ink);
  TextStyle get meta => DesignTokens.fieldType.copyWith(color: muted);
  TextStyle get field => DesignTokens.fieldType.copyWith(color: ink);
  TextStyle get body => DesignTokens.bodyType.copyWith(color: ink);
  TextStyle get supporting => DesignTokens.supportType.copyWith(color: muted);

  ThemeData get data {
    final buttons = ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(
        Size(0, DesignTokens.buttonPrimaryHeight),
      ),
      padding: const WidgetStatePropertyAll(DesignTokens.buttonPrimaryPadding),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DesignTokens.radiusButton),
        ),
      ),
      textStyle: WidgetStatePropertyAll(
        DesignTokens.buttonType.copyWith(fontFamily: fontFamily),
      ),
      side: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.focused)
            ? BorderSide(color: focus, width: 3)
            : BorderSide.none,
      ),
    );
    final fill = WidgetStateProperty.resolveWith<Color?>((states) {
      if (states.contains(WidgetState.disabled))
        return action.withValues(alpha: 0.12);
      if (states.contains(WidgetState.hovered)) return hover;
      return action;
    });
    return ThemeData(
      brightness: dark ? Brightness.dark : Brightness.light,
      useMaterial3: true,
      fontFamily: fontFamily,
      scaffoldBackgroundColor: background,
      canvasColor: sheet,
      focusColor: focus.withValues(alpha: 0.15),
      hoverColor: selected,
      colorScheme: ColorScheme(
        brightness: dark ? Brightness.dark : Brightness.light,
        primary: action,
        onPrimary: onAction,
        secondary: action,
        onSecondary: onAction,
        error: danger,
        onError: background,
        surface: sheet,
        onSurface: ink,
        onSurfaceVariant: muted,
        outline: border,
        outlineVariant: divider,
        surfaceContainerHighest: selected,
        surfaceTint: sheet.withValues(alpha: 0),
      ),
      textTheme: TextTheme(
        bodyLarge: body,
        bodyMedium: body,
        bodySmall: meta,
        titleLarge: title,
        titleMedium: label,
        labelLarge: DesignTokens.buttonType.copyWith(color: ink),
        headlineSmall: pageTitle,
      ),
      textButtonTheme: TextButtonThemeData(
        style: buttons.copyWith(foregroundColor: WidgetStatePropertyAll(ink)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: buttons.copyWith(
          backgroundColor: fill,
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) =>
                states.contains(WidgetState.disabled) ? muted : onAction,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: buttons.copyWith(
          foregroundColor: WidgetStatePropertyAll(ink),
          side: WidgetStateProperty.resolveWith(
            (states) => BorderSide(
              color: states.contains(WidgetState.focused) ? focus : border,
              width: states.contains(WidgetState.focused) ? 3 : 1,
            ),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        filled: true,
        fillColor: sheet,
        hintStyle: DesignTokens.fieldType.copyWith(
          color: dark ? DesignTokens.darkPlaceholder : DesignTokens.placeholder,
        ),
        contentPadding: DesignTokens.inputDefaultPadding,
        constraints: const BoxConstraints(
          minHeight: DesignTokens.inputDefaultHeight,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(DesignTokens.radiusMd),
          borderSide: BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(DesignTokens.radiusMd),
          borderSide: BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(DesignTokens.radiusMd),
          borderSide: BorderSide(color: focus, width: 3),
        ),
      ),
      dividerTheme: DividerThemeData(color: divider, thickness: 1),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: ink,
        selectionColor: selected,
        selectionHandleColor: focus,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: action,
        linearTrackColor: selected,
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStatePropertyAll(muted.withValues(alpha: 0.5)),
      ),
      tooltipTheme: TooltipThemeData(
        textStyle: DesignTokens.fieldType.copyWith(color: onAction),
        decoration: BoxDecoration(
          color: action,
          borderRadius: BorderRadius.circular(DesignTokens.radiusSm),
        ),
      ),
    );
  }
}
