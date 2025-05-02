import 'dart:developer';
import 'dart:io'; // Import Platform

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:hmssdk_flutter/hmssdk_flutter.dart';
import 'package:permission_handler/permission_handler.dart'; // Import permission_handler

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
  // Store maps containing track, peerId, and peerName
  List<Map<String, dynamic>> videoTracks = [];
  bool isVideoMuted = false; // Local user's video mute state
  bool permissionsGranted = false; // Track permission status

  // Helper function to get initials from a name
  String _getInitials(String name) {
    List<String> nameParts = name.trim().split(' ');
    if (nameParts.isEmpty || nameParts.first.isEmpty) {
      return "?"; // Default if name is empty
    }
    if (nameParts.length == 1) {
      return nameParts.first[0].toUpperCase(); // First letter if single name
    }
    return (nameParts.first[0] + nameParts.last[0])
        .toUpperCase(); // First letter of first and last name
  }

  Future<bool> _getPermissions() async {
    if (Platform.isIOS) return true; // Skip for iOS as requested

    // Request Camera and Mic permissions
    Map<Permission, PermissionStatus> statuses = await [
      Permission.camera,
      Permission.microphone,
    ].request();

    // Check if both permissions are granted
    bool granted = statuses[Permission.camera]!.isGranted &&
        statuses[Permission.microphone]!.isGranted;

    if (!granted) {
      log("Permissions not granted: Camera: ${statuses[Permission.camera]}, Mic: ${statuses[Permission.microphone]}");
      // Optionally, show a dialog or message to the user explaining why permissions are needed
      // You could use openAppSettings() from permission_handler to guide the user
    }
    return granted;
  }

  Future<void> _toggleVideo() async {
    if (!permissionsGranted) {
      log("Cannot toggle video: Permissions not granted.");
      // Optionally show a message to the user
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
    _initRoom(); // Call a new init function
  }

  Future<void> _initRoom() async {
    setState(() => isLoading = true);

    // 1. Get Permissions
    permissionsGranted = await _getPermissions();
    if (!permissionsGranted) {
      setState(() {
        error = "Camera and Microphone permissions are required.";
        isLoading = false;
      });
      return; // Stop if permissions are not granted
    }

    // 2. Get Room Code
    roomCode = dotenv.env["PREVIEW_ROOM_CODE"];
    if (roomCode == null) {
      setState(() {
        error = "PREVIEW_ROOM_CODE not found in .env";
        isLoading = false;
      });
      return; // Stop if room code is missing
    }

    // 3. Join Room (only if permissions granted and room code exists)
    await _joinDummyRoom();
  }

  Future<void> _joinDummyRoom() async {
    // No need to set isLoading here, it's done in _initRoom
    try {
      // Build SDK (moved here from original initState)
      await _hmsSDK.build();

      // Get Auth Token
      final authToken = await _hmsSDK.getAuthTokenByRoomCode(
          roomCode: roomCode!, userId: "default_user_id");

      final config = HMSConfig(
        userName: "Default User",
        authToken: authToken,
      );

      _hmsSDK.addUpdateListener(listener: this);
      await _hmsSDK.join(config: config);

      // Join successful
      setState(() {
        isJoined = true;
        isLoading = false; // Set loading false only on success or error
        error = null; // Clear any previous errors
      });
    } catch (e) {
      log("Error joining dummy room: $e");
      setState(() {
        error = "Error joining room: ${e.toString()}"; // Provide more context
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

  // HMS SDK Listener Methods
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
      // Find the index of the track data map based on trackId
      int trackIndex = videoTracks
          .indexWhere((map) => map['track'].trackId == track.trackId);

      setState(() {
        if (trackUpdate == HMSTrackUpdate.trackAdded) {
          if (trackIndex == -1) {
            // Add new track data map
            videoTracks.add({
              'track': track,
              'peerId': peer.peerId,
              'peerName': peer.name,
            });
            log("Added track for ${peer.name}");
          }
        } else if (trackUpdate == HMSTrackUpdate.trackRemoved) {
          if (trackIndex != -1) {
            // Remove track data map
            log("Removing track for ${videoTracks[trackIndex]['peerName']}");
            videoTracks.removeAt(trackIndex);
          }
        } else if (trackUpdate == HMSTrackUpdate.trackMuted ||
            trackUpdate == HMSTrackUpdate.trackUnMuted) {
          if (trackIndex != -1) {
            // Update the track object within the map to reflect mute status
            videoTracks[trackIndex]['track'] = track;
            log("Track mute status updated for ${peer.name}: ${track.isMute}");
          }
        }
        // Update local user's mute state if it's their track
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
    // Handle peer removal: remove all tracks associated with the removed peer
    setState(() {
      for (var peer in removedPeers) {
        videoTracks.removeWhere((map) => map['peerId'] == peer.peerId);
        log("Removed tracks for removed peer: ${peer.name}");
      }
    });
  }

  // Other required HMSUpdateListener methods with empty implementations
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

  // Removed didUpdateWidget logic that cleared videoTracks,
  // as it might interfere with state persistence during hot reload/widget updates.
  // @override
  // void didUpdateWidget(RoomScreen oldWidget) {
  //   super.didUpdateWidget(oldWidget);
  //   // videoTracks.clear(); // Let's not clear tracks on widget update for now
  // }

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
              const Text(
                  "Connecting..."), // Show connecting state if not loading, no error, but not joined yet
            if (isJoined &&
                permissionsGranted) // Only show grid if joined AND permissions granted
              Expanded(
                child: GridView.builder(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    childAspectRatio: 1,
                  ),
                  itemCount: videoTracks.length,
                  itemBuilder: (context, index) {
                    // Extract data from the map
                    final trackData = videoTracks[index];
                    final track = trackData['track'] as HMSVideoTrack;
                    final peerName = trackData['peerName'] as String;
                    final isMuted =
                        track.isMute; // Check mute status from the track object

                    return Card(
                      // Wrap in a Card for better visual separation
                      key: ValueKey(
                          track.trackId), // Use trackId from the track object
                      child: isMuted
                          ? // Display initials if muted
                          Center(
                              child: CircleAvatar(
                                radius: 40, // Adjust size as needed
                                backgroundColor:
                                    Colors.blueGrey, // Example background
                                child: Text(
                                  _getInitials(peerName),
                                  style: const TextStyle(
                                      fontSize: 24, color: Colors.white),
                                ),
                              ),
                            )
                          : // Display video if not muted
                          HMSVideoView(
                              track: track,
                              scaleType: ScaleType.SCALE_ASPECT_FIT,
                              setMirror: track.source ==
                                  "REGULAR", // Mirror front camera
                            ),
                    );
                  },
                ),
              ),
            // Removed the redundant roomCode check here as it's handled by the main error display
          ],
        ),
      ),
    );
  }
}
