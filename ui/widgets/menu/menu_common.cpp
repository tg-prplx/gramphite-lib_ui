// This file is part of Desktop App Toolkit,
// a set of libraries for developing nice desktop applications.
//
// For license and copyright information please follow this link:
// https://github.com/desktop-app/legal/blob/master/LEGAL
//
#include "ui/widgets/menu/menu_common.h"

#include "ui/effects/ripple_animation.h"
#include "ui/painter.h"
#include "ui/platform/ui_platform_utility.h"
#include "styles/style_widgets.h"

#include <QAction>
#include <QtWidgets/QWidget>

namespace Ui::Menu {

not_null<QAction*> CreateAction(
		QWidget *parent,
		const QString &text,
		Fn<void()> &&callback) {
	const auto action = new QAction(text, parent);
	parent->connect(
		action,
		&QAction::triggered,
		action,
		std::move(callback),
		Qt::QueuedConnection);
	return action;
}

void PaintItemBackground(
		QPainter &p,
		const style::Menu &st,
		QRect rect,
		bool selected) {
	if (!Platform::HasNativeGlass(dynamic_cast<QWidget*>(p.device()))) {
		p.fillRect(rect, st.itemBg);
	}
	if (!selected) {
		return;
	}
	const auto margin = st::menuItemOverMargin;
	const auto radius = st::menuItemOverRadius;
	PainterHighQualityEnabler hq(p);
	p.setPen(Qt::NoPen);
	auto background = st.itemBgOver->c;
	if (Platform::HasNativeGlass(dynamic_cast<QWidget*>(p.device()))) {
		background.setAlphaF(background.alphaF() * 0.35);
	}
	p.setBrush(background);
	p.drawRoundedRect(
		rect.marginsRemoved({ margin, 0, margin, 0 }),
		radius,
		radius);
}

QImage PrepareItemRippleMask(QSize size) {
	const auto margin = st::menuItemOverMargin;
	const auto radius = st::menuItemOverRadius;
	return RippleAnimation::MaskByDrawer(size, false, [&](QPainter &p) {
		p.drawRoundedRect(
			QRect(QPoint(), size).marginsRemoved({ margin, 0, margin, 0 }),
			radius,
			radius);
	});
}

} // namespace Ui::Menu
