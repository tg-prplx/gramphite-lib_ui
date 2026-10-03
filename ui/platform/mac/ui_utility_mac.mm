// This file is part of Desktop App Toolkit,
// a set of libraries for developing nice desktop applications.
//
// For license and copyright information please follow this link:
// https://github.com/desktop-app/legal/blob/master/LEGAL
//
#include "ui/platform/mac/ui_utility_mac.h"

#include "ui/integration.h"
#include "base/platform/mac/base_utilities_mac.h"
#include "styles/style_widgets.h"

#include <QtCore/QTimer>
#include <QtCore/QMap>
#include <QtGui/QPainter>
#include <QtGui/QPainterPath>
#include <QtGui/QtEvents>
#include <QtGui/QWindow>
#include <QtWidgets/QApplication>
#include <QtWidgets/QTextEdit>

#include <Cocoa/Cocoa.h>
#include <QuartzCore/QuartzCore.h>
#include <objc/runtime.h>

#ifndef OS_MAC_STORE
extern "C" {
void _dispatch_main_queue_callback_4CF(mach_msg_header_t *msg);
} // extern "C"
#endif // OS_MAC_STORE

namespace Ui {

int WidgetGrabDepth(); // ui/ui_utility.cpp

namespace Platform {

namespace {

QRegion RoundedChromeRegion(QRect rect, int radius) {
	if (!radius) {
		return QRegion(rect);
	}
	auto path = QPainterPath();
	path.addRoundedRect(QRectF(rect), radius, radius);
	return QRegion(path.toFillPolygon().toPolygon());
}

QRegion ChromeOccluders(QWidget *widget, QWidget *relative) {
	if (!widget->isVisible() || widget->window() != relative->window()) {
		return {};
	}
	if (widget->property("_td_chromeOccluder").toBool()) {
		const auto window = widget->window();
		const auto offset = widget->mapTo(window, QPoint())
			- relative->mapTo(window, QPoint());
		// Floating panels draw their shadow outside of the visible body,
		// only the body itself must cut a hole in the native chrome.
		const auto margins = widget->property(
			"_td_chromeOccluderMargins").value<QMargins>();
		auto region = RoundedChromeRegion(
			widget->rect().marginsRemoved(margins),
			widget->property("_td_chromeOccluderRadius").toInt());
		return region.translated(offset);
	}
	auto result = QRegion();
	for (const auto child : widget->children()) {
		if (const auto childWidget = qobject_cast<QWidget*>(child)) {
			result += ChromeOccluders(childWidget, relative);
		}
	}
	return result;
}

QRegion ChromeVisibleRegion(not_null<QWidget*> widget, QRect rect) {
	if (!widget->isVisible()) {
		return {};
	}
	auto region = QRegion(rect);
	for (auto parent = widget->parentWidget(); parent; parent = parent->parentWidget()) {
		region &= QRegion(parent->rect().translated(widget->mapFrom(parent, QPoint())));
	}
	// The history viewport deliberately extends beneath native chrome. Its
	// opaque Qt children are backdrop content, not chrome occluders. Only
	// explicit foreground layers may cut holes in these native surfaces.
	for (auto current = widget.get(); current->parentWidget(); current = current->parentWidget()) {
		auto above = false;
		for (const auto sibling : current->parentWidget()->children()) {
			if (sibling == current) {
				above = true;
			} else if (above) {
				if (const auto siblingWidget = qobject_cast<QWidget*>(sibling)) {
					region -= ChromeOccluders(siblingWidget, widget);
				}
			}
		}
	}
	return region;
}

void ClipChromeView(NSView *view, const QRegion &region) {
	[view setWantsLayer:YES];
	const auto path = CGPathCreateMutable();
	const auto height = NSHeight([view bounds]);
	for (const auto &rect : region) {
		const auto y = [view isFlipped] ? rect.y()
			: height - rect.y() - rect.height();
		CGPathAddRect(path, nullptr, CGRectMake(
			rect.x(), y, rect.width(), rect.height()));
	}
	// A standalone mask layer animates path changes implicitly,
	// which makes the chrome lag behind and flicker on every update.
	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	auto mask = static_cast<CAShapeLayer*>([[view layer] mask]);
	if (!mask) {
		mask = [CAShapeLayer layer];
		[[view layer] setMask:mask];
	}
	[mask setPath:path];
	[CATransaction commit];
	CGPathRelease(path);
}

NSView *GlassHitTest(id, SEL, NSPoint) {
	return nil;
}

#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 260000
API_AVAILABLE(macos(26.0))
Class NativeGlassClass() {
	// Register only on supported systems: older AppKit has no glass superclass.
	static const auto result = [] {
		const auto result = objc_allocateClassPair(
			[NSGlassEffectView class], "TDGlassBackdrop", 0);
		const auto selector = @selector(hitTest:);
		class_addMethod(
			result,
			selector,
			reinterpret_cast<IMP>(GlassHitTest),
			method_getTypeEncoding(class_getInstanceMethod([NSView class], selector)));
		objc_registerClassPair(result);
		return result;
	}();
	return result;
}
#endif

Class NativeChromeClass() {
	static const auto result = [] {
		const auto result = objc_allocateClassPair(
			[NSView class], "TDGlassChromeContent", 0);
		class_addMethod(result, @selector(hitTest:),
			reinterpret_cast<IMP>(GlassHitTest),
			method_getTypeEncoding(class_getInstanceMethod([NSView class], @selector(hitTest:))));
		objc_registerClassPair(result);
		return result;
	}();
	return result;
}

#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 260000
API_AVAILABLE(macos(26.0))
Class NativeGlassContainerClass() {
	static const auto result = [] {
		const auto result = objc_allocateClassPair(
			[NSView class], "TDGlassContainer", 0);
		class_addMethod(result, @selector(hitTest:),
			reinterpret_cast<IMP>(GlassHitTest),
			method_getTypeEncoding(class_getInstanceMethod([NSView class], @selector(hitTest:))));
		objc_registerClassPair(result);
		return result;
	}();
	return result;
}

class NativeGlassWindow final : public QObject {
public:
	explicit NativeGlassWindow(not_null<QWidget*> window) : QObject(window)
	, _window(window) {
		_container = [[NativeGlassContainerClass() alloc] initWithFrame:NSZeroRect];
		_content = [[NSView alloc] initWithFrame:NSZeroRect];
		[_container addSubview:_content];
		_dim = [[NativeGlassContainerClass() alloc] initWithFrame:NSZeroRect];
		[_dim setWantsLayer:YES];
		[_container addSubview:_dim];
		qApp->installEventFilter(this);
	}

	~NativeGlassWindow() {
		[_container removeFromSuperview];
		[_container release];
		[_content release];
		[_dim release];
		[_header release];
	}

	void updateHeader(QWidget *widget, NSRect rect, const QColor &background) {
		if (!_headers.contains(widget)) {
			connect(widget, &QObject::destroyed, this, [=] {
				_headers.remove(widget);
				refreshHeader();
			});
		}
		_headers[widget] = widget->isVisible() ? rect : NSZeroRect;
		if (!_header) {
			_header = [[NativeGlassClass() alloc] initWithFrame:NSZeroRect];
			[_header setCornerRadius:0];
			[_content addSubview:_header positioned:NSWindowBelow relativeTo:nil];
		}
		[_header setAppearance:[NSAppearance appearanceNamed:
			(background.lightnessF() < 0.5) ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua]];
		refreshHeader();
	}

	void refreshHeader() {
		auto bounds = NSZeroRect;
		for (auto i = _headers.cbegin(); i != _headers.cend(); ++i) {
			if (!NSIsEmptyRect(i.value())) {
				bounds = NSIsEmptyRect(bounds) ? i.value() : NSUnionRect(bounds, i.value());
			}
		}
		[_header setFrame:bounds];
		[_header setHidden:NSIsEmptyRect(bounds)];
		auto region = QRegion();
		for (auto i = _headers.cbegin(); i != _headers.cend(); ++i) {
			const auto widget = i.key();
			const auto offset = widget->mapTo(_window, QPoint());
			region += ChromeVisibleRegion(widget, widget->rect()).translated(offset);
		}
		const auto top = _window->height() - NSMaxY(bounds);
		ClipChromeView(_header, region.translated(-NSMinX(bounds), -top));
	}

	void watchSurface(QWidget *widget, Fn<void()> refresh) {
		if (_surfaces.contains(widget)) {
			return;
		}
		_surfaces[widget] = std::move(refresh);
		connect(widget, &QObject::destroyed, this, [=] {
			_surfaces.remove(widget);
			_surfaceRegions.remove(widget);
			refreshDim();
		});
	}

	void updateSurfaceRegion(QWidget *widget, QRegion region) {
		_surfaceRegions[widget] = std::move(region);
		refreshDim();
	}

	void refreshDim() {
		const auto color = (_dimmer && _dimmer->isVisible())
			? _dimmer->property("_td_chromeDim").value<QColor>()
			: QColor(Qt::transparent);
		[_dim setHidden:color.alpha() == 0];
		if (!color.alpha()) {
			return;
		}
		auto region = QRegion();
		for (const auto &part : _surfaceRegions) {
			region += part;
		}
		[_dim setFrame:[_container bounds]];
		[[_dim layer] setBackgroundColor:[[NSColor colorWithSRGBRed:color.redF()
			green:color.greenF() blue:color.blueF() alpha:color.alphaF()] CGColor]];
		ClipChromeView(_dim, region);
	}

	bool eventFilter(QObject *object, QEvent *event) override {
		const auto widget = qobject_cast<QWidget*>(object);
		const auto dimChanged = widget
			&& event->type() == QEvent::DynamicPropertyChange
			&& static_cast<QDynamicPropertyChangeEvent*>(event)->propertyName()
				== "_td_chromeDim";
		if (dimChanged && widget->window() == _window) {
			_dimmer = widget;
		}
		if (widget && widget->window() == _window
			&& (dimChanged || event->type() == QEvent::Show || event->type() == QEvent::Hide
				|| event->type() == QEvent::ZOrderChange
				|| ((event->type() == QEvent::Move || event->type() == QEvent::Resize)
					&& (widget->property("_td_chromeOccluder").toBool()
						|| widget->testAttribute(Qt::WA_OpaquePaintEvent)))) && !_queued) {
			_queued = true;
			QTimer::singleShot(0, this, [=] {
				_queued = false;
				refreshHeader();
				for (const auto &refresh : _surfaces) {
					refresh();
				}
				refreshDim();
			});
		}
		return QObject::eventFilter(object, event);
	}

	NSView *content(NSView *view) {
		const auto parent = [view superview];
		[_container setFrame:[parent convertRect:[view bounds] fromView:view]];
		[_content setFrame:[_container bounds]];
		if ([_container superview] != parent) {
			[parent addSubview:_container positioned:NSWindowAbove relativeTo:view];
		}
		return _content;
	}

private:
	not_null<QWidget*> _window;
	QMap<QWidget*, Fn<void()>> _surfaces;
	QMap<QWidget*, QRegion> _surfaceRegions;
	QPointer<QWidget> _dimmer;
	bool _queued = false;
	NSView *_container = nil;
	NSGlassEffectView *_header = nil;
	QMap<QWidget*, NSRect> _headers;
	NSView *_content = nil;
	NSView *_dim = nil;
};

API_AVAILABLE(macos(26.0))
NSView *ChromeParent(not_null<QWidget*> window, NSView *view) {
	auto holder = static_cast<NativeGlassWindow*>(
		window->property("_td_glassWindow").value<void*>());
	if (!holder) {
		holder = new NativeGlassWindow(window);
		window->setProperty("_td_glassWindow", QVariant::fromValue<void*>(holder));
	}
	return holder->content(view);
}
#endif

class NativeGlassBackdrop final : public QObject {
public:
	explicit NativeGlassBackdrop(not_null<QWidget*> widget)
	: QObject(widget)
	, _widget(widget) {
		watch(_widget);
		for (auto parent = _widget->parentWidget(); parent; parent = parent->parentWidget()) {
			parent->installEventFilter(this);
		}
	}

	~NativeGlassBackdrop() {
		[_glass removeFromSuperview];
		[_glass release];
		[_content removeFromSuperview];
		[_content release];
		[_contentLayer release];
	}

	void update(QRect rect, int radius, const QColor &background) {
		_rect = rect;
		_radius = radius;
		_background = background;
		updateGeometry();
		if (!_rendering) {
			queueRefresh();
		}
	}

	void updateGeometry() {
		auto rect = _rect;
		const auto radius = _radius;
		const auto &background = _background;
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 260000
		if (@available(macOS 26.0, *)) {
			const auto withinWindow = _widget->property(
				"_td_glassWithinWindow").toBool();
			const auto window = _widget->window();
			const auto view = reinterpret_cast<NSView*>(window->winId());
			const auto parent = withinWindow
				? ChromeParent(window, view) : [view superview];
			if (!parent) {
				return;
			}
			if (withinWindow) {
				const auto holder = static_cast<NativeGlassWindow*>(window->property(
					"_td_glassWindow").value<void*>());
				holder->watchSurface(_widget, [=] {
					updateGeometry();
					if (_content) {
						ClipChromeView(_content, ChromeVisibleRegion(_widget, _widget->rect()));
					}
				});
				holder->updateSurfaceRegion(_widget,
					(ChromeVisibleRegion(_widget, _rect)
						& RoundedChromeRegion(_rect, radius))
						.translated(_widget->mapTo(window, QPoint())));
			}
			if (rect.isEmpty()) {
				return;
			}
			rect.moveTopLeft(_widget->mapTo(window, rect.topLeft()));
			const auto y = [view isFlipped]
				? rect.y()
				: window->height() - rect.y() - rect.height();
			const auto frame = [parent convertRect:NSMakeRect(
				rect.x(), y, rect.width(), rect.height()) fromView:view];
			if (withinWindow && !radius) {
				static_cast<NativeGlassWindow*>(window->property(
					"_td_glassWindow").value<void*>())->updateHeader(_widget, frame, background);
				return;
			}
			if (!_glass) {
				_glass = [[NativeGlassClass() alloc] initWithFrame:NSZeroRect];
			}
			const auto glass = static_cast<NSGlassEffectView*>(_glass);
			[glass setStyle:NSGlassEffectViewStyleRegular];
			[glass setCornerRadius:radius];
			[glass setAppearance:[NSAppearance appearanceNamed:
				(background.lightnessF() < 0.5)
					? NSAppearanceNameDarkAqua
					: NSAppearanceNameAqua]];
			[glass setFrame:frame];
			if (withinWindow) {
				ClipChromeView(glass, ChromeVisibleRegion(_widget, _rect)
					.translated(-_rect.topLeft()));
			}
			if (withinWindow) {
				// Glass and its transparent controls share the window coordinate
				// system; Qt widgets remain in their existing scene and input tree.
				if ([glass superview] != parent) {
					[parent addSubview:glass positioned:NSWindowBelow relativeTo:nil];
				}
				if (_content && [_content superview] != parent) {
					[parent addSubview:_content positioned:NSWindowAbove relativeTo:glass];
				}
			} else if ([glass superview] != parent) {
				[parent addSubview:glass positioned:NSWindowBelow relativeTo:view];
			}
			[[view window] setOpaque:NO];
			[[view window] setBackgroundColor:[NSColor clearColor]];
		}
#endif
	}

	void setOpacity(float64 opacity) {
		[_glass setAlphaValue:opacity];
	}

	void watch(QObject *object) {
		if (const auto widget = qobject_cast<QWidget*>(object);
			widget && widget != _widget && (widget->isWindow()
				|| widget->property("_td_glassWithinWindow").toBool())) {
			return;
		}
		object->installEventFilter(this);
		clearOpaque(object);
		for (const auto child : object->children()) {
			watch(child);
		}
	}

	// Qt never paints beneath opaque widgets, in a translucent window that
	// leaves a hole down to the desktop which the glass then blurs. Content
	// captured into the native chrome must leave the backdrop to Qt.
	void clearOpaque(QObject *object) {
		if (!_widget->property("_td_glassWithinWindow").toBool()) {
			return;
		}
		const auto widget = qobject_cast<QWidget*>(object);
		if (widget && widget->testAttribute(Qt::WA_OpaquePaintEvent)) {
			widget->setAttribute(Qt::WA_OpaquePaintEvent, false);
			widget->update();
		}
	}

	void queueRefresh() {
		if (!_widget->property("_td_glassWithinWindow").toBool()
			|| _queued || _rendering) {
			return;
		}
		_queued = true;
		QTimer::singleShot(0, this, [=] { refreshContent(); });
	}

	void refreshContent() {
		_queued = false;
		if (!_widget->isVisible() || _widget->size().isEmpty()) {
			return;
		}
		const auto ratio = _widget->devicePixelRatioF();
		QImage image(_widget->size() * ratio, QImage::Format_ARGB32_Premultiplied);
		if (image.isNull()) {
			return;
		}
		image.setDevicePixelRatio(ratio);
		image.fill(Qt::transparent);
		_rendering = true;
		_widget->render(&image, QPoint(), QRegion(), QWidget::DrawChildren);
		_rendering = false;
		paintFocusedCaret(image);
		const auto window = _widget->window();
		const auto view = reinterpret_cast<NSView*>(window->winId());
		NSView *parent = nil;
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 260000
		if (@available(macOS 26.0, *)) {
			parent = ChromeParent(window, view);
		}
#endif
		if (!parent) {
			return;
		}
		// Swap the capture without any implicit Core Animation transition,
		// otherwise consecutive frames cross-fade and the content flickers.
		[CATransaction begin];
		[CATransaction setDisableActions:YES];
		const auto commit = gsl::finally([] { [CATransaction commit]; });
		if (!_content) {
			_content = [[NativeChromeClass() alloc] initWithFrame:NSZeroRect];
			[_content setWantsLayer:YES];
			_contentLayer = [[CALayer alloc] init];
			[_contentLayer setContentsGravity:kCAGravityResize];
			[_contentLayer setAutoresizingMask:
				(kCALayerWidthSizable | kCALayerHeightSizable)];
			[[_content layer] addSublayer:_contentLayer];
		}
		if (const auto cgImage = image.toCGImage()) {
			[_contentLayer setContentsScale:ratio];
			[_contentLayer setContents:(id)cgImage];
			CGImageRelease(cgImage);
		}
		const auto position = _widget->mapTo(window, QPoint());
		const auto y = [view isFlipped] ? position.y()
			: window->height() - position.y() - _widget->height();
		[_content setFrame:[parent convertRect:NSMakeRect(
			position.x(), y, _widget->width(), _widget->height()) fromView:view]];
		[_contentLayer setFrame:[[_content layer] bounds]];
		updateGeometry();
		if ([_content superview] != parent) {
			[parent addSubview:_content positioned:NSWindowAbove relativeTo:nil];
		}
		ClipChromeView(_content, ChromeVisibleRegion(_widget, _widget->rect()));
		[_content setHidden:NO];
	}

	// The text cursor of a focused field doesn't reliably make it into
	// the capture (input method events may hide it), and without it the
	// captured field shows no caret at all. Draw it over the capture.
	void paintFocusedCaret(QImage &image) const {
		const auto focused = QApplication::focusWidget();
		const auto edit = qobject_cast<QTextEdit*>(focused);
		if (!edit
			|| edit->isReadOnly()
			|| !edit->isActiveWindow()
			|| edit->textCursor().hasSelection()
			|| (edit != _widget && !_widget->isAncestorOf(edit))) {
			return;
		}
		const auto viewport = edit->viewport();
		auto caret = edit->cursorRect();
		caret.setWidth(std::max(edit->cursorWidth(), 1));
		caret.moveTopLeft(viewport->mapTo(_widget, caret.topLeft()));
		auto p = QPainter(&image);
		p.setClipRect(QRect(viewport->mapTo(_widget, QPoint()), viewport->size()));
		p.fillRect(caret, edit->palette().color(QPalette::Text));
	}

protected:
	bool eventFilter(QObject *object, QEvent *event) override {
		// Popups can be owned by a toolbar while painting into another window.
		if (const auto widget = qobject_cast<QWidget*>(object);
			widget && widget->window() != _widget->window()) {
			return QObject::eventFilter(object, event);
		}
		const auto withinWindow = _widget->property("_td_glassWithinWindow").toBool();
		const auto target = qobject_cast<QWidget*>(object);
		const auto inside = target && (target == _widget || _widget->isAncestorOf(target));
		// Nested glass surfaces capture their controls independently.
		// Their paint events must not be swallowed by an ancestor's capture.
		if (withinWindow && inside) {
			for (auto current = target; current != _widget; current = current->parentWidget()) {
				if (current->property("_td_glassWithinWindow").toBool()) {
					return QObject::eventFilter(object, event);
				}
			}
		}
		if (withinWindow && !inside) {
			if (event->type() == QEvent::Move || event->type() == QEvent::Resize
				|| event->type() == QEvent::Show || event->type() == QEvent::ZOrderChange) {
				queueRefresh();
			}
			return QObject::eventFilter(object, event);
		}
		// Grabs for animations render the widgets themselves, let them paint.
		if (withinWindow
			&& event->type() == QEvent::Paint
			&& !_rendering
			&& !WidgetGrabDepth()) {
			clearOpaque(object);
			queueRefresh();
			return true;
		} else if (withinWindow && event->type() == QEvent::ChildPolished) {
			watch(static_cast<QChildEvent*>(event)->child());
		} else if (object == _widget && event->type() == QEvent::Hide) {
			if (withinWindow && !_radius && !_rect.isEmpty()) {
				updateGeometry();
			}
			[_glass setHidden:YES];
			[_content setHidden:YES];
			// Don't flash the previous content when shown again,
			// refreshContent() reveals the view with a fresh capture.
			[CATransaction begin];
			[CATransaction setDisableActions:YES];
			[_contentLayer setContents:nil];
			[CATransaction commit];
		} else if (object == _widget && event->type() == QEvent::Show) {
			[_glass setHidden:NO];
			queueRefresh();
		} else if (withinWindow && (event->type() == QEvent::Move
			|| event->type() == QEvent::Resize || event->type() == QEvent::ZOrderChange)) {
			queueRefresh();
		}
		return QObject::eventFilter(object, event);
	}

private:
	not_null<QWidget*> _widget;
	NSView *_glass = nil;
	NSView *_content = nil;
	CALayer *_contentLayer = nil;
	QRect _rect;
	QColor _background;
	int _radius = 0;
	bool _rendering = false;
	bool _queued = false;

};

} // namespace

bool NativeGlassSupported() {
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 260000
	if (@available(macOS 26.0, *)) {
		return true;
	}
#endif
	return false;
}

bool HasNativeGlass(const QWidget *widget) {
	for (auto current = widget; current; current = current->parentWidget()) {
		if (current->property("_td_nativeGlass").toBool()) {
			return true;
		} else if (current->isWindow()) {
			break;
		}
	}
	return false;
}

void InitNativeGlassWithinWindow(not_null<QWidget*> widget) {
	if (!NativeGlassSupported()) {
		return;
	}
	widget->setProperty("_td_nativeGlass", true);
	widget->setProperty("_td_glassWithinWindow", true);
	auto holder = new NativeGlassBackdrop(widget);
	widget->setProperty("_td_glassBackdrop", QVariant::fromValue<void*>(holder));
	widget->setAttribute(Qt::WA_NoSystemBackground);
	widget->setAttribute(Qt::WA_OpaquePaintEvent, false);
}

void SetNativeGlass(
		not_null<QWidget*> widget,
		QRect rect,
		int radius,
		const QColor &background) {
	if (!NativeGlassSupported() || rect.isEmpty()) {
		return;
	}
	auto holder = static_cast<NativeGlassBackdrop*>(
		widget->property("_td_glassBackdrop").value<void*>());
	if (!holder) {
		holder = new NativeGlassBackdrop(widget);
		widget->setProperty("_td_glassBackdrop", QVariant::fromValue<void*>(holder));
	}
	holder->update(rect, radius, background);
}

void SetNativeGlassOpacity(not_null<QWidget*> widget, float64 opacity) {
	if (const auto holder = static_cast<NativeGlassBackdrop*>(
			widget->property("_td_glassBackdrop").value<void*>())) {
		holder->setOpacity(opacity);
	}
}

bool IsApplicationActive() {
	return [[NSApplication sharedApplication] isActive];
}

void InitOnTopPanel(not_null<QWidget*> panel) {
	Expects(!panel->windowHandle());

	// Force creating windowHandle() without creating the platform window yet.
	panel->setAttribute(Qt::WA_NativeWindow, true);
	panel->windowHandle()->setProperty("_td_macNonactivatingPanelMask", QVariant(true));
	panel->setAttribute(Qt::WA_NativeWindow, false);

	panel->createWinId();

	auto platformWindow = [reinterpret_cast<NSView*>(panel->winId()) window];
	Assert([platformWindow isKindOfClass:[NSPanel class]]);

	auto platformPanel = static_cast<NSPanel*>(platformWindow);
	[platformPanel setBackgroundColor:[NSColor clearColor]];
	[platformPanel setLevel:NSModalPanelWindowLevel];
	[platformPanel setCollectionBehavior:NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorStationary|NSWindowCollectionBehaviorFullScreenAuxiliary|NSWindowCollectionBehaviorIgnoresCycle];
	[platformPanel setHidesOnDeactivate:NO];
	//[platformPanel setFloatingPanel:YES];

	Integration::Instance().activationFromTopPanel();
}

void DeInitOnTopPanel(not_null<QWidget*> panel) {
	auto platformWindow = [reinterpret_cast<NSView*>(panel->winId()) window];
	Assert([platformWindow isKindOfClass:[NSPanel class]]);

	auto platformPanel = static_cast<NSPanel*>(platformWindow);
	auto newBehavior = ([platformPanel collectionBehavior] & (~NSWindowCollectionBehaviorCanJoinAllSpaces)) | NSWindowCollectionBehaviorMoveToActiveSpace;
	[platformPanel setCollectionBehavior:newBehavior];
}

void ReInitOnTopPanel(not_null<QWidget*> panel) {
	auto platformWindow = [reinterpret_cast<NSView*>(panel->winId()) window];
	Assert([platformWindow isKindOfClass:[NSPanel class]]);

	auto platformPanel = static_cast<NSPanel*>(platformWindow);
	auto newBehavior = ([platformPanel collectionBehavior] & (~NSWindowCollectionBehaviorMoveToActiveSpace)) | NSWindowCollectionBehaviorCanJoinAllSpaces;
	[platformPanel setCollectionBehavior:newBehavior];
}

void ShowOverAll(not_null<QWidget*> widget, bool canFocus) {
	NSWindow *wnd = [reinterpret_cast<NSView*>(widget->winId()) window];

	auto behavior = [wnd collectionBehavior];

	if (widget->windowFlags() & Qt::Popup) {
		behavior |= NSWindowCollectionBehaviorMoveToActiveSpace;
	}

	if (!canFocus) {
		[wnd setStyleMask:NSWindowStyleMaskUtilityWindow
			| NSWindowStyleMaskNonactivatingPanel];
		behavior |= NSWindowCollectionBehaviorMoveToActiveSpace
			| NSWindowCollectionBehaviorStationary
			| NSWindowCollectionBehaviorFullScreenAuxiliary
			| NSWindowCollectionBehaviorIgnoresCycle;
	}

	[wnd setCollectionBehavior:behavior];
}

void AcceptAllMouseInput(not_null<QWidget*> widget) {
	// https://github.com/telegramdesktop/tdesktop/issues/27025
	//
	// By default system clicks through fully transparent pixels,
	// and starting with macOS 14.1 it counts the transparency
	// incorrectly (as if `y` is mirrored), so when clicking
	// on a reactions strip outside of the menu column the click
	// is ignored and made on the underlying window, because at the
	// bottom of the menu in the same place there is nothing, empty.
	//
	// We explicitly request all the input to disable this behavior.
	//
	// See https://stackoverflow.com/a/29451199 and comments.
	NSWindow *window = [reinterpret_cast<NSView*>(widget->winId()) window];
	[window setIgnoresMouseEvents:NO];
}

void DrainMainQueue() {
#ifndef OS_MAC_STORE
	_dispatch_main_queue_callback_4CF(nullptr);
#endif // OS_MAC_STORE
}

void IgnoreAllActivation(not_null<QWidget*> widget) {
}

void DisableSystemWindowResize(not_null<QWidget*> widget, QSize ratio) {
	const auto winId = widget->winId();
	if (const auto view = reinterpret_cast<NSView*>(winId)) {
		if (const auto window = [view window]) {
			window.styleMask &= ~NSWindowStyleMaskResizable;
		}
	}
}

SystemTextReplaceResult FindSystemTextReplace(const QString &text) {
	if (text.isEmpty()) {
		return {};
	}
	NSSpellChecker *checker = nil;
	@try {
		checker = [NSSpellChecker sharedSpellChecker];
	} @catch (id exception) {
		return {};
	}
	if (!checker) {
		return {};
	}
	const auto nsText = ::Platform::Q2NSString(text);
	const auto results = [checker
		checkString:nsText
		range:NSMakeRange(0, nsText.length)
		types:NSTextCheckingTypeReplacement
		options:nil
		inSpellDocumentWithTag:0
		orthography:nil
		wordCount:nil];
	for (NSTextCheckingResult *result in results) {
		if (result.resultType != NSTextCheckingTypeReplacement) {
			continue;
		}
		const auto matchEnd = result.range.location + result.range.length;
		if (matchEnd == NSUInteger(text.length())) {
			return {
				.length = int(result.range.length),
				.replacement = ::Platform::NS2QString(
					result.replacementString),
			};
		}
	}
	return {};
}

} // namespace Platform
} // namespace Ui
