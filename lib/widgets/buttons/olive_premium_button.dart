import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';

class OlivePremiumButton extends StatefulWidget {
  final IconData icon;
  final String title;
  final String description;
  final VoidCallback onTap;

  const OlivePremiumButton({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    required this.onTap,
  });

  @override
  State<OlivePremiumButton> createState() => _OlivePremiumButtonState();
}

class _OlivePremiumButtonState extends State<OlivePremiumButton> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accentColor = isDark
        ? const Color(0xFFC4D5AF)
        : const Color(0xFF536B3D);
    final bgColor = isDark
        ? AppColors.surfaceVariantDark
        : const Color(0xFFF6F8F3);
    final borderColor = isDark ? AppColors.borderDark : const Color(0xFFDCE4D3);
    final titleColor = isDark
        ? AppColors.textPrimaryDark
        : AppColors.textPrimary;
    final subtextColor = isDark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondary;

    return AnimatedScale(
      scale: _isPressed ? 0.97 : 1.0,
      duration: const Duration(milliseconds: 100),
      child: Container(
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: borderColor, width: 1.2),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onTap,
            onTapDown: (_) => setState(() => _isPressed = true),
            onTapCancel: () => setState(() => _isPressed = false),
            onHighlightChanged: (highlighted) {
              if (!highlighted) {
                setState(() => _isPressed = false);
              }
            },
            borderRadius: BorderRadius.circular(16),
            splashColor: accentColor.withValues(alpha: 0.15),
            highlightColor: accentColor.withValues(alpha: 0.08),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: isDark
                          ? const Color(0xFF2A3127)
                          : const Color(0xFFE8EFE0),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(widget.icon, color: accentColor, size: 24),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.title,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: titleColor,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          widget.description,
                          style: TextStyle(fontSize: 12, color: subtextColor),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
