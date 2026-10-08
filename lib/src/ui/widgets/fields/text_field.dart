import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'base_field.dart';
import 'field_helpers.dart';

/// Widget for Text, Long Text, and Small Text field types
class TextFieldWidget extends BaseField {
  const TextFieldWidget({
    super.key,
    required super.field,
    super.value,
    super.onChanged,
    super.enabled,
    super.style,
  });

  @override
  Widget buildField(BuildContext context) {
    final isLongText =
        field.fieldtype == 'Long Text' || field.fieldtype == 'Text';
    final maxLines = isLongText ? 5 : 3;
    final editable = enabled && !field.readOnly;

    Widget buildInput(ScrollController? scrollController) =>
        FormBuilderTextField(
          autovalidateMode: AutovalidateMode.onUserInteraction,
          key: ValueKey('text_${field.fieldname}'),
          name: field.fieldname ?? '',
          initialValue: value?.toString() ?? field.defaultValue ?? '',
          enabled: editable,
          inputFormatters: style?.inputFormatters,
          decoration: baseFieldDecoration(field, style: style),
          maxLines: maxLines,
          scrollController: scrollController,
          maxLength: (field.length != null && field.length! > 0)
              ? field.length
              : null,
          validator: field.reqd
              ? (value) => requiredValidator(value, field.displayLabel)
              : null,
          onChanged: (val) => onChanged?.call(val),
        );

    // Always the same root widget: switching it on editable would tear down
    // the form field (controller, focus, registration) whenever
    // read_only_depends_on flips. Only [active] changes between the two.
    return _DisabledTextScroll(active: !editable, builder: buildInput);
  }
}

/// Makes a disabled multi-line text box scrollable inside its fixed height.
///
/// Flutter wraps a disabled `TextField` in an `IgnorePointer`, so text past
/// `maxLines` is clipped with no way to reach it. This drives the field's own
/// scroll controller from a drag detector placed OUTSIDE that IgnorePointer.
/// The detector is attached only while [active] and the text actually
/// overflows, so an editable or short disabled field behaves exactly as
/// before. Once the text is scrolled to either end, the rest of the drag is
/// handed to the enclosing page so the field never traps page scrolling.
class _DisabledTextScroll extends StatefulWidget {
  const _DisabledTextScroll({required this.active, required this.builder});

  /// False for an editable field: no controller is injected and no drag
  /// recognizer is registered, leaving the native TextField untouched.
  final bool active;
  final Widget Function(ScrollController? controller) builder;

  @override
  State<_DisabledTextScroll> createState() => _DisabledTextScrollState();
}

class _DisabledTextScrollState extends State<_DisabledTextScroll> {
  final ScrollController _controller = ScrollController();
  bool _overflows = false;

  @override
  void initState() {
    super.initState();
    if (widget.active) _scheduleOverflowCheck();
  }

  @override
  void didUpdateWidget(covariant _DisabledTextScroll oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active == oldWidget.active) return;
    if (widget.active) {
      _scheduleOverflowCheck();
    } else {
      _overflows = false;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _scheduleOverflowCheck() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkOverflow());
  }

  void _checkOverflow() {
    if (!mounted || !widget.active || !_controller.hasClients) return;
    final overflows = _controller.position.maxScrollExtent > 0;
    if (overflows != _overflows) setState(() => _overflows = overflows);
  }

  void _onDrag(DragUpdateDetails details) {
    if (!_controller.hasClients) return;
    final inner = _controller.position;
    // Positive = move content up (reveal text further down).
    final delta = -(details.primaryDelta ?? details.delta.dy);
    final target = (inner.pixels + delta).clamp(
      inner.minScrollExtent,
      inner.maxScrollExtent,
    );
    final remainder = delta - (target - inner.pixels);
    if (target != inner.pixels) _controller.jumpTo(target);
    if (remainder != 0) _scrollPage(remainder);
  }

  /// Hands the part of a drag the text box could not use to the page.
  void _scrollPage(double delta) {
    final page = Scrollable.maybeOf(context)?.position;
    if (page == null || page.axis != Axis.vertical) return;
    final signed = page.axisDirection == AxisDirection.up ? -delta : delta;
    final target = (page.pixels + signed).clamp(
      page.minScrollExtent,
      page.maxScrollExtent,
    );
    if (target != page.pixels) page.jumpTo(target);
  }

  @override
  Widget build(BuildContext context) {
    // The tree shape stays fixed (only the callback toggles) so the form
    // field's state is never torn down when overflow or [active] changes.
    // A null callback registers no drag recognizer at all.
    final dragEnabled = widget.active && _overflows;
    return GestureDetector(
      behavior: widget.active
          ? HitTestBehavior.opaque
          : HitTestBehavior.deferToChild,
      onVerticalDragUpdate: dragEnabled ? _onDrag : null,
      child: NotificationListener<ScrollMetricsNotification>(
        onNotification: (_) {
          if (widget.active) _scheduleOverflowCheck();
          return false;
        },
        child: widget.builder(widget.active ? _controller : null),
      ),
    );
  }
}
