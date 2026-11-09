import 'package:flutter/material.dart';

import '../../i18n.dart';

/// "Copies" with − and + buttons (1..99).
class CopiesStepper extends StatelessWidget {
  const CopiesStepper({super.key, required this.value, required this.onChanged});

  final int value;

  /// null disables the buttons.
  final ValueChanged<int>? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final change = onChanged;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton.outlined(
          tooltip: '−',
          onPressed: change == null || value <= 1 ? null : () => change(value - 1),
          icon: const Icon(Icons.remove),
        ),
        SizedBox(
          width: 44,
          child: Text(
            '$value',
            textAlign: TextAlign.center,
            semanticsLabel: '${tr('Copies')}: $value',
            style: theme.textTheme.titleLarge,
          ),
        ),
        IconButton.outlined(
          tooltip: '+',
          onPressed: change == null || value >= 99 ? null : () => change(value + 1),
          icon: const Icon(Icons.add),
        ),
      ],
    );
  }
}
