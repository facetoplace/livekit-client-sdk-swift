//
//  File.swift
//  
//
//  Created by Russell D'Sa on 11/7/20.
//

import Foundation
import WebRTC
import Promises
import Starscream
import Semver

enum RoomError: Error {
    case missingRoomId(String)
}

public class Room {
    public typealias Sid = String

    public var delegate: RoomDelegate?
    
    public private(set) var sid: Room.Sid?
    public private(set) var name: String?
    public private(set) var state: RoomState = .disconnected
    public private(set) var localParticipant: LocalParticipant?
    public private(set) var remoteParticipants = [Participant.Sid: RemoteParticipant]()
    public private(set) var activeSpeakers: [Participant] = []
    
    private var connectOptions: ConnectOptions
    private var client: RTCClient
    private var engine: RTCEngine
    private var joinPromise: Promise<Room>?
    
    init(options: ConnectOptions) {
        connectOptions = options
        client = RTCClient()
        engine = RTCEngine(client: client)
        engine.delegate = self
    }
    
    func connect() throws -> Promise<Room> {
        joinPromise = Promise<Room>.pending()
        
        guard localParticipant == nil else {
            print("Already connected to room: \(name!)")
            DispatchQueue.main.async {
                self.joinPromise?.fulfill(self)
            }
            return joinPromise!
        }
        
        engine.join(options: connectOptions)
        return joinPromise!
    }
    
    func disconnect() {
        engine.close()
        state = .disconnected
        delegate?.didDisconnect(room: self, error: nil)
    }
    
    private func handleParticipantDisconnect(sid: Participant.Sid, participant: RemoteParticipant) {
        guard let participant = remoteParticipants.removeValue(forKey: sid) else {
            return
        }
        participant.tracks.values.forEach { publication in
            do {
                try participant.unpublishTrack(sid: publication.trackSid)
            } catch {
                print("room --- error unpublishing track (\(publication.trackSid)): \(error)")
            }
        }
        delegate?.participantDidDisconnect(room: self, participant: participant)
    }
    
    private func getOrCreateRemoteParticipant(sid: Participant.Sid, info: Livekit_ParticipantInfo? = nil) -> RemoteParticipant {
        if let participant = remoteParticipants[sid] {
            return participant
        }
        let participant = info != nil ? RemoteParticipant(info: info!) : RemoteParticipant(sid: sid, name: nil)
        remoteParticipants[sid] = participant
        return participant
    }
    
    private func handleSpeakerUpdate(speakers: [Livekit_SpeakerInfo]) {
        var activeSpeakers: [Participant] = []
        var seenSids = [String: Bool]()
        for speaker in speakers {
            seenSids[speaker.sid] = true
            if speaker.sid == localParticipant?.sid {
                localParticipant?.audioLevel = speaker.level
                activeSpeakers.append(localParticipant!)
            } else {
                if let participant = remoteParticipants[speaker.sid] {
                    participant.audioLevel = speaker.level
                    activeSpeakers.append(participant)
                }
            }
        }
        
        if seenSids[localParticipant!.sid!] == nil {
            localParticipant?.audioLevel = 0.0
        }
        for participant in remoteParticipants.values {
            if seenSids[participant.sid!] == nil {
                participant.audioLevel = 0.0
            }
        }
        self.activeSpeakers = activeSpeakers
        delegate?.activeSpeakersDidChange(speakers: activeSpeakers, room: self)
    }
}

extension Room: RTCEngineDelegate {
    func didUpdateSpeakers(speakers: [Livekit_SpeakerInfo]) {
        print("engine delegate --- received speaker update")
        handleSpeakerUpdate(speakers: speakers)
    }
    
    func didDisconnect(reason: String) {
        print("engine delegate --- did disconnect", reason)
    }
    
    func didPublishLocalTrack(cid: String, track: Livekit_TrackInfo) {
        
    }
    
    func didJoin(response: Livekit_JoinResponse) {
        print("engine delegate --- did join, version: \(response.serverVersion)")
        
        if let sv = Semver(response.serverVersion) {
            if !(sv.major >= 0 && sv.minor <= 5) {
                print("engine delegate --- error: requires server >= 0.5.x")
                return
            }
        } else {
            print("engine delegate --- error: unknown server version")
            return
        }
        
        state = .connected
        sid = response.room.sid
        name = response.room.name
        
        if response.hasParticipant {
            localParticipant = LocalParticipant(fromInfo: response.participant, engine: engine)
        }
        if !response.otherParticipants.isEmpty {
            for otherParticipant in response.otherParticipants {
                let _ = getOrCreateRemoteParticipant(sid: otherParticipant.sid, info: otherParticipant)
            }
        }
        
        delegate?.didConnect(room: self)
        joinPromise?.fulfill(self)
    }
    
    func didAddTrack(track: RTCMediaStreamTrack, streams: [RTCMediaStream]) {
        guard streams.count > 0 else {
            print("Received event that track with empty streams array!")
            return
        }
        
        print("engine delegate --- did add media track")
        let participantSid = streams[0].streamId
        let trackSid = track.trackId
        let participant = getOrCreateRemoteParticipant(sid: participantSid)
        do {
            try participant.addSubscribedMediaTrack(rtcTrack: track, sid: trackSid)
        } catch {
            print(error)
        }
    }
    
    func didAddDataChannel(channel: RTCDataChannel) {
        print("engine delegate --- did add data channel")
        var participantSid: Participant.Sid, trackSid: Track.Sid, name: String
        (participantSid, trackSid, name) = channel.unpackedTrackLabel
        
        let participant = getOrCreateRemoteParticipant(sid: participantSid)
        do {
            try participant.addSubscribedDataTrack(rtcTrack: channel, sid: trackSid, name: name)
        } catch {
            print(error)
        }
    }
    
    func didUpdateParticipants(updates: [Livekit_ParticipantInfo]) {
        print("engine delegate --- did update participants")
        for info in updates {
            let isNewParticipant = remoteParticipants[info.sid] == nil
            let participant = getOrCreateRemoteParticipant(sid: info.sid, info: info)
            
            if info.state == .disconnected {
                handleParticipantDisconnect(sid: info.sid, participant: participant)
            } else if (isNewParticipant) {
                delegate?.participantDidConnect(room: self, participant: participant)
            } else {
                do {
                    try participant.updateFromInfo(info: info)
                } catch {
                    print("engine delegate --- error updating participant (\(participant.sid!)) info")
                }
            }
        }
    }
    
    func didDisconnect(reason: String, code: UInt16) {
        var error: Error?
        if code != CloseCode.normal.rawValue {
            error = RTCClientError.socketError(reason, code)
        }
        delegate?.didDisconnect(room: self, error: error)
    }
    
    func didFailToConnect(error: Error) {
        delegate?.didFailToConnect(room: self, error: error)
    }
}