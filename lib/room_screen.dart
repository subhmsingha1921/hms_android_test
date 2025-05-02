import 'dart:developer';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:hmssdk_flutter/hmssdk_flutter.dart';
import 'package:permission_handler/permission_handler.dart';

class RoomScreen extends StatefulWidget {
  const RoomScreen({super.key});

  @override
  State<RoomScreen> createState() => _RoomScreenState();
}

class _RoomScreenState extends State<RoomScreen> implements HMSUpdateListener {
  late HMSSDK _hmsSDK;
  bool isLoading = true;
  String? error;
  bool isJoined = false;
  String? roomCode;
  List<Map<String, dynamic>> videoTracks = [];
  bool isVideoMuted = false;
  bool permissionsGranted = false;

  String _getInitials(String name) {
    List<String> nameParts = name.trim().split(' ');
    if (nameParts.isEmpty || nameParts.first.isEmpty) {
      return "?";
    }
    if (nameParts.length == 1) {
      return nameParts.first[0].toUpperCase();
    }
    return (nameParts.first[0] + nameParts.last[0]).toUpperCase();
  }

  Future<bool> _getPermissions() async {
    if (Platform.isIOS) return true;

    Map<Permission, PermissionStatus> statuses = await [
      Permission.camera,
      Permission.microphone,
    ].request();

    bool granted = statuses[Permission.camera]!.isGranted &&
        statuses[Permission.microphone]!.isGranted;

    if (!granted) {
      log("Permissions not granted: Camera: ${statuses[Permission.camera]}, Mic: ${statuses[Permission.microphone]}");
    }
    return granted;
  }

  Future<void> _toggleVideo() async {
    if (!permissionsGranted) {
      log("Cannot toggle video: Permissions not granted.");
      return;
    }
    try {
      await _hmsSDK.toggleCameraMuteState();
      setState(() {
        isVideoMuted = !isVideoMuted;
      });
    } catch (e) {
      log("Error toggling video: $e");
    }
  }

  @override
  void initState() {
    super.initState();
    _hmsSDK = HMSSDK();
    _initRoom();
  }

  Future<void> _initRoom() async {
    setState(() => isLoading = true);

    permissionsGranted = await _getPermissions();
    if (!permissionsGranted) {
      setState(() {
        error = "Camera and Microphone permissions are required.";
        isLoading = false;
      });
      return;
    }

    roomCode = dotenv.env["PREVIEW_ROOM_CODE"];
    if (roomCode == null) {
      setState(() {
        error = "PREVIEW_ROOM_CODE not found in .env";
        isLoading = false;
      });
      return;
    }

    await _joinDummyRoom();
  }

  Future<void> _joinDummyRoom() async {
    try {
      await _hmsSDK.build();

      final authToken = await _hmsSDK.getAuthTokenByRoomCode(
          roomCode: roomCode!, userId: "default_user_id");

      final config = HMSConfig(
        userName: "Default User",
        authToken: authToken,
      );

      _hmsSDK.addUpdateListener(listener: this);
      await _hmsSDK.join(config: config);

      setState(() {
        isJoined = true;
        isLoading = false;
        error = null;
      });
    } catch (e) {
      log("Error joining dummy room: $e");
      setState(() {
        error = "Error joining room: ${e.toString()}";
        isLoading = false;
      });
    }
  }

  @override
  void dispose() {
    _hmsSDK.leave();
    _hmsSDK.removeUpdateListener(listener: this);
    super.dispose();
  }

  @override
  void onJoin({required HMSRoom room}) {
    log("HMS Event - onJoin: ${room.name}");
  }

  @override
  void onPeerUpdate({required HMSPeer peer, required HMSPeerUpdate update}) {
    log("HMS Event - onPeerUpdate: ${peer.peerId} - ${update.toString()}");
  }

  @override
  void onTrackUpdate(
      {required HMSTrack track,
      required HMSTrackUpdate trackUpdate,
      required HMSPeer peer}) {
    log("HMS Event - onTrackUpdate: Peer: ${peer.name}, Track: ${track.trackId}, Update: ${trackUpdate.toString()}");

    if (track is HMSVideoTrack) {
      int trackIndex = videoTracks
          .indexWhere((map) => map['track'].trackId == track.trackId);

      setState(() {
        if (trackUpdate == HMSTrackUpdate.trackAdded) {
          if (trackIndex == -1) {
            videoTracks.add({
              'track': track,
              'peerId': peer.peerId,
              'peerName': peer.name,
            });
            log("Added track for ${peer.name}");
          }
        } else if (trackUpdate == HMSTrackUpdate.trackRemoved) {
          if (trackIndex != -1) {
            log("Removing track for ${videoTracks[trackIndex]['peerName']}");
            videoTracks.removeAt(trackIndex);
          }
        } else if (trackUpdate == HMSTrackUpdate.trackMuted ||
            trackUpdate == HMSTrackUpdate.trackUnMuted) {
          if (trackIndex != -1) {
            videoTracks[trackIndex]['track'] = track;
            log("Track mute status updated for ${peer.name}: ${track.isMute}");
          }
        }

        if (peer.isLocal) {
          isVideoMuted = track.isMute;
        }
      });
    }
  }

  @override
  void onHMSError({required HMSException error}) {
    log("HMS Error: ${error.message}");
  }

  @override
  void onPeerListUpdate({
    required List<HMSPeer> addedPeers,
    required List<HMSPeer> removedPeers,
  }) {
    log("HMS Event - Peer list updated: Added ${addedPeers.map((p) => p.name)}, Removed ${removedPeers.map((p) => p.name)}");

    setState(() {
      for (var peer in removedPeers) {
        videoTracks.removeWhere((map) => map['peerId'] == peer.peerId);
        log("Removed tracks for removed peer: ${peer.name}");
      }
    });
  }

  @override
  void onAudioDeviceChanged(
      {HMSAudioDevice? currentAudioDevice,
      List<HMSAudioDevice>? availableAudioDevice}) {}

  @override
  void onMessage({required HMSMessage message}) {}

  @override
  void onReconnected() {}

  @override
  void onReconnecting() {}

  @override
  void onRemovedFromRoom(
      {required HMSPeerRemovedFromPeer hmsPeerRemovedFromPeer}) {}

  @override
  void onRoleChangeRequest({required HMSRoleChangeRequest roleChangeRequest}) {}

  @override
  void onChangeTrackStateRequest(
      {required HMSTrackChangeRequest hmsTrackChangeRequest}) {}

  @override
  void onRoomUpdate({required HMSRoom room, required HMSRoomUpdate update}) {}

  @override
  void onUpdateSpeakers({required List<HMSSpeaker> updateSpeakers}) {}

  @override
  void onSessionStoreAvailable({HMSSessionStore? hmsSessionStore}) {}

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Dummy Room Test'),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _toggleVideo,
        child: Icon(isVideoMuted ? Icons.videocam_off : Icons.videocam),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (isLoading) const CircularProgressIndicator(),
            if (error != null)
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Text(
                  'Error: $error',
                  style: const TextStyle(color: Colors.red, fontSize: 16),
                  textAlign: TextAlign.center,
                ),
              ),
            if (!isLoading &&
                error == null &&
                !isJoined &&
                permissionsGranted &&
                roomCode != null)
              const Text("Connecting..."),
            if (isJoined && permissionsGranted)
              Expanded(
                child: GridView.builder(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    childAspectRatio: 1,
                  ),
                  itemCount: videoTracks.length,
                  itemBuilder: (context, index) {
                    final trackData = videoTracks[index];
                    final track = trackData['track'] as HMSVideoTrack;
                    final peerName = trackData['peerName'] as String;
                    final isMuted = track.isMute;

                    return Card(
                      key: ValueKey(track.trackId),
                      child: isMuted
                          ? Center(
                              child: CircleAvatar(
                                radius: 40,
                                backgroundColor: Colors.blueGrey,
                                child: Text(
                                  _getInitials(peerName),
                                  style: const TextStyle(
                                      fontSize: 24, color: Colors.white),
                                ),
                              ),
                            )
                          : HMSVideoView(
                              track: track,
                              scaleType: ScaleType.SCALE_ASPECT_FILL,
                              setMirror: track.source == "REGULAR",
                            ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
