import 'package:flutter/material.dart';

/// Optional styling for [LoginScreen]. All fields are optional; defaults come from theme.
class LoginScreenStyle {
  final TextStyle? titleStyle;
  final double? iconSize;
  final Color? iconColor;
  final InputDecoration? baseUrlDecoration;
  final InputDecoration? usernameDecoration;
  final InputDecoration? passwordDecoration;
  final InputDecoration? mobileDecoration;
  final InputDecoration? otpDecoration;
  final ButtonStyle? loginButtonStyle;
  final ButtonStyle? mobileButtonStyle;
  final ButtonStyle? oauthButtonStyle;
  final ButtonStyle? socialButtonStyle;
  final TextStyle? orDividerTextStyle;
  final EdgeInsets? padding;
  final Color? errorBackgroundColor;
  final TextStyle? errorTextStyle;

  const LoginScreenStyle({
    this.titleStyle,
    this.iconSize,
    this.iconColor,
    this.baseUrlDecoration,
    this.usernameDecoration,
    this.passwordDecoration,
    this.mobileDecoration,
    this.otpDecoration,
    this.loginButtonStyle,
    this.mobileButtonStyle,
    this.oauthButtonStyle,
    this.socialButtonStyle,
    this.orDividerTextStyle,
    this.padding,
    this.errorBackgroundColor,
    this.errorTextStyle,
  });
}
