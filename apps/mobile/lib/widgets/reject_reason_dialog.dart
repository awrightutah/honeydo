import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Shows the standard reject-with-reason AlertDialog and returns the user's
/// input. Used by Batch 4b's chore reject path (chore_dashboard +
/// chore_detail), and by Batch 5b-i's Approvals screen.
///
/// Return values:
///   - `null` — the user tapped Cancel (no submission should occur).
///   - empty string `''` — the user tapped Reject without typing anything;
///     the caller is responsible for converting this to `null` when passing
///     as `p_reason` to the `approve_chore` RPC so the DB stores a NULL
///     `rejected_reason`.
///   - non-empty string — the typed reason.
///
/// The dialog body is a `StatefulWidget` so the State class owns the
/// `TextEditingController` lifecycle. The previous inline-controller form
/// disposed the controller immediately after `await showDialog(...)`
/// returned — but `showDialog` returns when `Navigator.pop` is called,
/// which is BEFORE the dismissal animation completes. The TextField was
/// still rebuilding against the now-disposed controller during the
/// animation frame, throwing 'TextEditingController used after being
/// disposed' and cascading into a `_dependents.isEmpty` assertion. Letting
/// `State.dispose()` clean up the controller fixes this — it fires after
/// the widget tree fully unmounts, post-animation.
Future<String?> showRejectReasonDialog(
  BuildContext context,
  String itemName, {
  String verb = 'Reject',
}) {
  return showDialog<String?>(
    context: context,
    builder: (ctx) => _RejectReasonDialog(itemName: itemName, verb: verb),
  );
}

class _RejectReasonDialog extends StatefulWidget {
  const _RejectReasonDialog({required this.itemName, required this.verb});
  final String itemName;
  final String verb;

  @override
  State<_RejectReasonDialog> createState() => _RejectReasonDialogState();
}

class _RejectReasonDialogState extends State<_RejectReasonDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('${widget.verb} "${widget.itemName}"?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Tell them why (optional):'),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            maxLines: 3,
            maxLength: 500,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              hintText: 'e.g. Try again — room still has clothes on the floor',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, null),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          style: FilledButton.styleFrom(backgroundColor: AppColors.coral),
          child: Text(widget.verb),
        ),
      ],
    );
  }
}
