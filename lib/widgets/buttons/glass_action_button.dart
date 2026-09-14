import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';

class GlassActionButton extends StatefulWidget {
  final IconData icon;
  final Color color;
  final String tooltip;
  final VoidCallback onPressed;

  const GlassActionButton({
    super.key,
    required this.icon,
    required this.color,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  State<GlassActionButton> createState() => _GlassActionButtonState();
}

class _GlassActionButtonState extends State<GlassActionButton> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final buttonColor = widget.color;
    final isCollect =
        buttonColor == Colors.green || buttonColor == AppColors.collectText;
    final isPay = buttonColor == Colors.red || buttonColor == AppColors.payText;

    final Color bgColor;
    final Color borderColor;
    final Color iconColor;

    if (isDark) {
      bgColor = const Color(0xFF1E222A);
      borderColor = const Color(0xFF2D323E);
      iconColor = isCollect
          ? const Color(0xFF34D399)
          : (isPay ? const Color(0xFFF87171) : buttonColor);
    } else {
      bgColor = isCollect
          ? AppColors.collectBg
          : (isPay ? AppColors.payBg : AppColors.surfaceVariant);
      borderColor = isCollect
          ? AppColors.collectBadge
          : (isPay ? AppColors.payBadge : AppColors.borderLight);
      iconColor = isCollect
          ? AppColors.collectText
          : (isPay ? AppColors.payText : buttonColor);
    }

    return Tooltip(
      message: widget.tooltip,
      child: GestureDetector(
        onTapDown: (_) => setState(() => _isPressed = true),
        onTapUp: (_) => setState(() => _isPressed = false),
        onTapCancel: () => setState(() => _isPressed = false),
        onTap: widget.onPressed,
        child: AnimatedScale(
          scale: _isPressed ? 0.92 : 1.0,
          duration: const Duration(milliseconds: 100),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: borderColor, width: 1.0),
            ),
            child: Center(child: Icon(widget.icon, color: iconColor, size: 18)),
          ),
        ),
      ),
    );
  }
}
