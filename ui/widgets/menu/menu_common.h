// This file is part of Desktop App Toolkit,
// a set of libraries for developing nice desktop applications.
//
// For license and copyright information please follow this link:
// https://github.com/desktop-app/legal/blob/master/LEGAL
//
#pragma once

namespace style {
struct Menu;
} // namespace style

namespace Ui::Menu {

enum class TriggeredSource {
	Mouse,
	Keyboard,
};

struct CallbackData {
	QAction *action = nullptr;
	int actionTop = 0;
	TriggeredSource source;
	int index = 0;
	bool selected = false;
	bool preventClose = false;
};

not_null<QAction*> CreateAction(
	QWidget *parent,
	const QString &text,
	Fn<void()> &&callback);

void PaintItemBackground(
	QPainter &p,
	const style::Menu &st,
	QRect rect,
	bool selected);
[[nodiscard]] QImage PrepareItemRippleMask(QSize size);

} // namespace Ui::Menu
