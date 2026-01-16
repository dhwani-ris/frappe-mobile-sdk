# UI Customization Guide

This guide explains how to customize the UI of `frappe_mobile_sdk` to match your app's design.

## Table of Contents

1. [Quick Start](#quick-start)
2. [Styling Options](#styling-options)
3. [Custom Field Factory](#custom-field-factory)
4. [Custom Field Widgets](#custom-field-widgets)
5. [Extending Widgets](#extending-widgets)
6. [Examples](#examples)

## Quick Start

The simplest way to customize styling is using `FrappeFormStyle`:

```dart
FrappeFormBuilder(
  meta: meta,
  style: FrappeFormStyle(
    labelStyle: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
    sectionTitleStyle: TextStyle(fontSize: 20, color: Colors.blue),
    fieldPadding: EdgeInsets.symmetric(vertical: 12),
  ),
)
```

## Styling Options

### FrappeFormStyle

Use `FrappeFormStyle` to customize form appearance:

```dart
FrappeFormStyle(
  // Custom InputDecoration for all text fields
  fieldDecoration: (field) => InputDecoration(
    labelText: field.displayLabel,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
    ),
    filled: true,
    fillColor: Colors.grey[50],
  ),
  
  // Custom label text style
  labelStyle: TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w500,
    color: Colors.black87,
  ),
  
  // Custom description text style
  descriptionStyle: TextStyle(
    fontSize: 12,
    color: Colors.grey[600],
    fontStyle: FontStyle.italic,
  ),
  
  // Custom section title style
  sectionTitleStyle: TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.bold,
    color: Colors.blue[700],
  ),
  
  // Custom section card margin
  sectionMargin: EdgeInsets.only(bottom: 24),
  
  // Custom section card padding
  sectionPadding: EdgeInsets.all(20),
  
  // Custom field spacing
  fieldPadding: EdgeInsets.only(bottom: 16),
)
```

### FieldStyle

For individual field customization, use `FieldStyle`:

```dart
FieldStyle(
  labelStyle: TextStyle(color: Colors.blue),
  descriptionStyle: TextStyle(fontSize: 11),
  decoration: InputDecoration(
    prefixIcon: Icon(Icons.person),
    suffixIcon: Icon(Icons.check),
  ),
)
```

## Custom Field Factory

Create a custom `FieldFactory` to control how fields are created:

```dart
class MyCustomFieldFactory extends FieldFactory {
  MyCustomFieldFactory({super.linkOptionService});

  @override
  BaseField? createField({
    required DocField field,
    dynamic value,
    ValueChanged<dynamic>? onChanged,
    bool enabled = true,
    List<String>? linkOptions,
    FieldStyle? style,
  }) {
    // Custom logic for specific field types
    if (field.fieldtype == 'CustomType') {
      return MyCustomField(
        field: field,
        value: value,
        onChanged: onChanged,
        enabled: enabled,
      );
    }
    
    // Use default behavior for other fields
    return super.createField(
      field: field,
      value: value,
      onChanged: onChanged,
      enabled: enabled,
      linkOptions: linkOptions,
      style: style,
    );
  }
}

// Use it:
FrappeFormBuilder(
  meta: meta,
  customFieldFactory: MyCustomFieldFactory(
    linkOptionService: linkOptionService,
  ),
)
```

## Custom Field Widgets

### Extending BaseField

Create custom field widgets by extending `BaseField`:

```dart
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';

class MyCustomTextField extends BaseField {
  const MyCustomTextField({
    super.key,
    required super.field,
    super.value,
    super.onChanged,
    super.enabled,
    super.style,
  });

  @override
  Widget buildField(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 4,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: TextFormField(
        initialValue: value?.toString() ?? '',
        enabled: enabled && !field.readOnly,
        decoration: style?.decoration ?? InputDecoration(
          hintText: field.placeholder ?? 'Enter ${field.displayLabel}',
          border: InputBorder.none,
          contentPadding: EdgeInsets.all(16),
        ),
        onChanged: onChanged,
        validator: validate,
      ),
    );
  }
}
```

### Using Custom Fields

Add your custom field to the factory:

```dart
class MyFieldFactory extends FieldFactory {
  @override
  BaseField? createField({...}) {
    switch (field.fieldtype) {
      case FieldTypes.text:
        return MyCustomTextField(
          field: field,
          value: value,
          onChanged: onChanged,
          enabled: enabled,
          style: style,
        );
      // ... other cases
    }
  }
}
```

## Extending Widgets

### Extending FormScreen

Customize the entire form screen:

```dart
class MyCustomFormScreen extends FormScreen {
  const MyCustomFormScreen({
    super.key,
    required super.meta,
    super.document,
    required super.repository,
    super.syncService,
    super.linkOptionService,
    super.onSaveSuccess,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.meta.label ?? widget.meta.name),
        backgroundColor: Colors.purple,
        foregroundColor: Colors.white,
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.purple[100]!, Colors.white],
          ),
        ),
        child: FrappeFormBuilder(
          meta: widget.meta,
          initialData: widget.document?.data,
          onSubmit: _handleSubmit,
          readOnly: _isSaving,
          linkOptionService: widget.linkOptionService,
          style: FrappeFormStyle(
            sectionTitleStyle: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Colors.purple[700],
            ),
          ),
        ),
      ),
    );
  }
}
```

### Extending FrappeFormBuilder

For more control, extend `FrappeFormBuilder`:

```dart
class MyFormBuilder extends FrappeFormBuilder {
  const MyFormBuilder({
    super.key,
    required super.meta,
    super.initialData,
    super.onSubmit,
    super.readOnly,
    super.linkOptionService,
    super.customFieldFactory,
    super.style,
  });

  @override
  State<FrappeFormBuilder> createState() => _MyFormBuilderState();
}

class _MyFormBuilderState extends _FrappeFormBuilderState {
  @override
  Widget build(BuildContext context) {
    // Custom build logic
    return Container(
      padding: EdgeInsets.all(16),
      child: super.build(context),
    );
  }
}
```

## Examples

### Example 1: Material Design 3 Style

```dart
FrappeFormBuilder(
  meta: meta,
  style: FrappeFormStyle(
    fieldDecoration: (field) => InputDecoration(
      labelText: field.displayLabel,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      filled: true,
      fillColor: Colors.grey[50],
    ),
    sectionTitleStyle: TextStyle(
      fontSize: 20,
      fontWeight: FontWeight.w600,
    ),
    sectionMargin: EdgeInsets.only(bottom: 24),
  ),
)
```

### Example 2: Minimalist Style

```dart
FrappeFormBuilder(
  meta: meta,
  style: FrappeFormStyle(
    fieldDecoration: (field) => InputDecoration(
      labelText: field.displayLabel,
      border: UnderlineInputBorder(),
      contentPadding: EdgeInsets.symmetric(vertical: 8),
    ),
    sectionMargin: EdgeInsets.zero,
    sectionPadding: EdgeInsets.symmetric(vertical: 16),
  ),
)
```

### Example 3: Custom Field for Specific Type

```dart
class PhoneField extends BaseField {
  const PhoneField({
    super.key,
    required super.field,
    super.value,
    super.onChanged,
    super.enabled,
    super.style,
  });

  @override
  Widget buildField(BuildContext context) {
    return TextFormField(
      initialValue: value?.toString() ?? '',
      keyboardType: TextInputType.phone,
      enabled: enabled && !field.readOnly,
      decoration: style?.decoration ?? InputDecoration(
        hintText: field.placeholder ?? 'Enter phone number',
        prefixIcon: Icon(Icons.phone),
        border: OutlineInputBorder(),
      ),
      onChanged: onChanged,
      validator: validate,
    );
  }
}

class PhoneFieldFactory extends FieldFactory {
  @override
  BaseField? createField({...}) {
    if (field.fieldname == 'phone' || field.fieldname == 'mobile_no') {
      return PhoneField(
        field: field,
        value: value,
        onChanged: onChanged,
        enabled: enabled,
        style: style,
      );
    }
    return super.createField(...);
  }
}
```

### Example 4: Themed Form

```dart
class ThemedFormBuilder extends StatelessWidget {
  final DocTypeMeta meta;
  final Map<String, dynamic>? initialData;
  final Function(Map<String, dynamic>)? onSubmit;

  const ThemedFormBuilder({
    Key? key,
    required this.meta,
    this.initialData,
    this.onSubmit,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    return FrappeFormBuilder(
      meta: meta,
      initialData: initialData,
      onSubmit: onSubmit,
      style: FrappeFormStyle(
        labelStyle: theme.textTheme.bodyLarge,
        sectionTitleStyle: theme.textTheme.headlineSmall,
        fieldDecoration: (field) => InputDecoration(
          labelText: field.displayLabel,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
          ),
          filled: true,
          fillColor: theme.colorScheme.surface,
        ),
      ),
    );
  }
}
```

## Best Practices

1. **Use FrappeFormStyle for global styling** - Apply consistent styles across all forms
2. **Extend FieldFactory for logic changes** - When you need conditional field creation
3. **Extend BaseField for new field types** - Create reusable custom field widgets
4. **Use Theme.of(context)** - Respect user's system theme preferences
5. **Keep customizations minimal** - Only override what you need to change

## API Reference

### FrappeFormStyle

| Property | Type | Description |
|----------|------|-------------|
| `fieldDecoration` | `InputDecoration Function(DocField)?` | Custom decoration builder for text fields |
| `labelStyle` | `TextStyle?` | Custom label text style |
| `descriptionStyle` | `TextStyle?` | Custom description text style |
| `sectionTitleStyle` | `TextStyle?` | Custom section title style |
| `sectionMargin` | `EdgeInsets?` | Custom section card margin |
| `sectionPadding` | `EdgeInsets?` | Custom section card padding |
| `fieldPadding` | `EdgeInsets?` | Custom field spacing |

### FieldStyle

| Property | Type | Description |
|----------|------|-------------|
| `labelStyle` | `TextStyle?` | Custom label text style |
| `descriptionStyle` | `TextStyle?` | Custom description text style |
| `decoration` | `InputDecoration?` | Custom input decoration |

### FieldFactory

| Method | Description |
|--------|-------------|
| `createField()` | Override to customize field creation logic |

### BaseField

| Property | Description |
|----------|-------------|
| `field` | The DocField metadata |
| `value` | Current field value |
| `onChanged` | Callback when value changes |
| `enabled` | Whether field is enabled |
| `style` | Custom FieldStyle |

| Method | Description |
|--------|-------------|
| `buildField()` | Override to create custom field widget |
| `validate()` | Override to add custom validation |
