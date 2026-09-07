import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'vlc_player_config.dart';
import 'vlc_player_controller.dart';
import 'vlc_player_controller_internals.dart';
import 'vlc_player_value.dart';
import 'vlc_video_fit.dart';

const String _viewType = 'plugins.lingjhf.com/vlc_player/view';

/// Widget that hosts the native VLC video output.
///
/// Every platform renders to a Flutter texture by default, so one Dart path
/// fits, clips and composites the video everywhere. Windows and Linux have
/// only that path; Android, macOS and iOS can fall back to a native platform
/// view - see [androidRenderer] and [darwinRenderer]. The owning widget
/// should dispose the [controller] when playback is no longer needed.
class VlcPlayer extends StatefulWidget {
  /// Creates a VLC player widget controlled by [controller].
  const VlcPlayer({
    super.key,
    required this.controller,
    this.backgroundColor = Colors.black,
    this.fit = VlcVideoFit.contain,
    this.darwinRenderer = VlcPlayerConfig.defaultDarwinRenderer,
    this.androidRenderer = VlcPlayerConfig.defaultAndroidRenderer,
  });

  /// Controller used to load media, control playback, and observe state.
  final VlcPlayerController controller;

  /// Background color shown behind the native video output.
  final Color backgroundColor;

  /// How video should be fitted inside this widget.
  final VlcVideoFit fit;

  /// How the video reaches the screen on macOS and iOS.
  ///
  /// Pass `config.darwinRenderer`. It arrives here rather than through the
  /// controller because the controller keeps the flattened libVLC option list
  /// and the renderer is not a libVLC option.
  ///
  /// Read once, in [State.initState]: the choice decides whether this widget
  /// asks the plugin for a platform view or for a texture, and changing it
  /// afterwards would mean tearing the engine down mid-playback.
  final VlcDarwinRenderer darwinRenderer;

  /// How the video reaches the screen on Android.
  ///
  /// Pass `config.androidRenderer`. Same contract as [darwinRenderer]: not a
  /// libVLC option, so it cannot travel through the controller, and read once
  /// in [State.initState] because switching it means tearing the engine down.
  final VlcAndroidRenderer androidRenderer;

  @override
  State<VlcPlayer> createState() => _VlcPlayerState();
}

class _VlcPlayerState extends State<VlcPlayer> {
  Future<int>? _textureId;
  int _textureGeneration = 0;
  bool _isDisposed = false;

  /// The platform view this State created, so teardown can name it.
  ///
  /// Null on the texture platforms, where the controller creates the view and
  /// the id never comes back here. See [_detachPlayer].
  int? _platformViewId;

  @override
  void initState() {
    super.initState();
    if (_usesTexturePlayer) {
      _textureId = _attachTexturePlayer(widget.controller);
    }
  }

  @override
  void didUpdateWidget(VlcPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Fit is applied to the running player rather than rebuilding the view.
    if (oldWidget.fit != widget.fit && widget.controller.isAttached) {
      unawaited(widget.controller.setFit(widget.fit));
    }

    if (oldWidget.controller == widget.controller) {
      return;
    }

    if (_usesTexturePlayer) {
      _textureId = _attachTexturePlayer(widget.controller);
      unawaited(_detachPlayer(oldWidget.controller));
    } else {
      unawaited(_detachPlayer(oldWidget.controller));
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    _textureGeneration++;
    // Named, because this is the call that races: a host that swaps the widget
    // at this slot builds the replacement and attaches its platform view
    // before the outgoing element is disposed, so an unqualified detach here
    // kills the player that has just started.
    unawaited(_detachPlayer(widget.controller, viewId: _platformViewId));
    super.dispose();
  }

  /// Exhaustive on purpose: a platform added to Flutter has to be placed here
  /// before this compiles. Fuchsia is the one platform with no plugin at all,
  /// so it falls through to the unsupported message.
  bool get _usesTexturePlayer => switch (defaultTargetPlatform) {
    TargetPlatform.android =>
      widget.androidRenderer == VlcAndroidRenderer.texture,
    TargetPlatform.macOS ||
    TargetPlatform.iOS => widget.darwinRenderer == VlcDarwinRenderer.texture,
    TargetPlatform.windows || TargetPlatform.linux => true,
    TargetPlatform.fuchsia => false,
  };

  @override
  Widget build(BuildContext context) {
    // Ahead of every platform-view branch: Android, iOS and macOS can render
    // either way, and this is the choice that decides it.
    if (_usesTexturePlayer) {
      return ColoredBox(
        color: widget.backgroundColor,
        child: FutureBuilder<int>(
          future: _textureId,
          builder: (context, snapshot) {
            final textureId = snapshot.data;
            if (textureId != null) {
              return ValueListenableBuilder<VlcPlayerValue>(
                valueListenable: widget.controller,
                builder: (context, value, child) {
                  return _fitTexture(
                    textureId,
                    value.videoSize,
                    value.codedVideoSize,
                  );
                },
              );
            }
            if (snapshot.hasError) {
              return Center(
                child: Text(
                  snapshot.error.toString(),
                  textAlign: TextAlign.center,
                ),
              );
            }
            return const Center(child: CircularProgressIndicator());
          },
        ),
      );
    }

    if (defaultTargetPlatform == TargetPlatform.android) {
      return ColoredBox(
        color: widget.backgroundColor,
        child: _excludeFromFocus(
          AndroidView(
            key: ValueKey<String>(_platformViewKey),
            viewType: _viewType,
            creationParams: <String, Object?>{
              'options': widget.controller.options,
              'fit': widget.fit.name,
            },
            creationParamsCodec: const StandardMessageCodec(),
            onPlatformViewCreated: _handlePlatformViewCreated,
          ),
        ),
      );
    }

    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return ColoredBox(
        color: widget.backgroundColor,
        child: _excludeFromFocus(
          UiKitView(
            key: ValueKey<String>(_platformViewKey),
            viewType: _viewType,
            creationParams: <String, Object?>{
              'options': widget.controller.options,
              'fit': widget.fit.name,
            },
            creationParamsCodec: const StandardMessageCodec(),
            onPlatformViewCreated: _handlePlatformViewCreated,
          ),
        ),
      );
    }

    if (defaultTargetPlatform != TargetPlatform.macOS) {
      return ColoredBox(
        color: widget.backgroundColor,
        child: const Center(
          child: Text(
            'vlc_player currently supports Android, iOS, macOS, Windows and Linux only.',
          ),
        ),
      );
    }

    return ColoredBox(
      color: widget.backgroundColor,
      child: _excludeFromFocus(
        AppKitView(
          key: ValueKey<String>(_platformViewKey),
          viewType: _viewType,
          creationParams: <String, Object?>{
            'options': widget.controller.options,
            'fit': widget.fit.name,
          },
          creationParamsCodec: const StandardMessageCodec(),
          onPlatformViewCreated: _handlePlatformViewCreated,
        ),
      ),
    );
  }

  /// Wraps the platform view so it never participates in focus traversal.
  ///
  /// Flutter inserts a `Focus` node around every platform view — see
  /// `flutter/lib/src/widgets/platform_view.dart`, which declares `_focusNode`,
  /// builds `Focus(focusNode: _focusNode, ...)` and installs an `onFocus`
  /// callback that calls `requestFocus()`. That node exists regardless of what
  /// the native view does, and it defaults to `canRequestFocus: true` /
  /// `skipTraversal: false`.
  ///
  /// On a TV that is a real bug, not a nicety. A full-screen video surface is a
  /// focusable candidate covering the whole screen, so when a host hides its
  /// controls (and with them their focus nodes) the video node is the only
  /// thing left to take focus. Hosts that detect "nothing is focused" by
  /// comparing `FocusManager.instance.primaryFocus` against their own root then
  /// see something focused, stand aside, and no one handles the remote's
  /// Play/Pause. Focus also becomes invisible.
  ///
  /// `ExcludeFocus` sets `descendantsAreFocusable: false`, drops the node from
  /// `traversalDescendants`, and neutralises the engine's `requestFocus`.
  /// Texture-backed platforms do not need this — a `Texture` contributes no
  /// focus node — which is why this only wraps the platform-view branches.
  Widget _excludeFromFocus(Widget platformView) =>
      ExcludeFocus(child: platformView);

  void _handlePlatformViewCreated(int viewId) {
    _platformViewId = viewId;
    unawaited(_attachPlatformView(widget.controller, viewId));
  }

  /// Deliberately excludes `fit`.
  ///
  /// It used to be part of this key, which meant every change of video fit
  /// tore down and rebuilt the platform view — recreating the entire LibVLC
  /// instance and stalling playback. Fit is now pushed to the running player
  /// via setFit() in didUpdateWidget.
  String get _platformViewKey => '${identityHashCode(widget.controller)}';

  Future<int> _attachTexturePlayer(VlcPlayerController controller) async {
    final generation = ++_textureGeneration;
    final textureId = await _attachTextureBackedPlayer(controller);
    if (_isDisposed ||
        generation != _textureGeneration ||
        widget.controller != controller) {
      await _detachPlayer(controller);
    }
    return textureId;
  }

  Future<void> _attachPlatformView(VlcPlayerController controller, int viewId) {
    return (controller as VlcPlayerControllerInternals).attach(viewId);
  }

  Future<int> _attachTextureBackedPlayer(VlcPlayerController controller) {
    return (controller as VlcPlayerControllerInternals).attachTexturePlayer();
  }

  /// [viewId] is only ever passed where this State knows which view it owns.
  /// A controller swap detaches the outgoing controller unconditionally: that
  /// one is being abandoned wholesale, and its view id is not ours to reason
  /// about.
  Future<void> _detachPlayer(VlcPlayerController controller, {int? viewId}) {
    return (controller as VlcPlayerControllerInternals).detach(viewId: viewId);
  }

  Widget _fitTexture(int textureId, Size? videoSize, Size? codedSize) {
    final texture = Texture(textureId: textureId);
    final visible = videoSize;
    if (visible == null) {
      return SizedBox.expand(child: texture);
    }

    // The texture is the decoder's whole buffer. For heights that are not a
    // multiple of 16 - 1080 is the everyday case - that buffer carries padding
    // rows libVLC never writes, and unwritten NV12 is green. Lay the texture
    // out at its coded size and clip to the visible picture, anchored top-left
    // where the real rows are.
    final coded = codedSize ?? visible;
    Widget picture = SizedBox(
      width: coded.width,
      height: coded.height,
      child: texture,
    );
    if (coded != visible) {
      picture = ClipRect(
        child: Align(
          alignment: Alignment.topLeft,
          widthFactor: visible.width / coded.width,
          heightFactor: visible.height / coded.height,
          child: picture,
        ),
      );
    }

    // SizedBox.expand, not Center: under loose constraints a FittedBox takes
    // its child's natural size, so a 1080p picture sat at 1:1 in the middle of
    // a larger window while 4K only filled it because it had to shrink. Tight
    // constraints make the box the viewport and let the fit do its job.
    return SizedBox.expand(
      child: FittedBox(
        fit: switch (widget.fit) {
          VlcVideoFit.contain => BoxFit.contain,
          VlcVideoFit.cover => BoxFit.cover,
          VlcVideoFit.none => BoxFit.none,
          VlcVideoFit.fill => BoxFit.fill,
        },
        child: picture,
      ),
    );
  }
}
