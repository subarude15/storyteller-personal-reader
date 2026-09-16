import Foundation
import Testing

@testable import SilveranKit

/// ponytail: smoke that Glance metadata + shared skip stay coherent for Lock Screen.
@Test func nowPlayingInfoCarriesLockScreenFields() {
    let art = Data([0x89, 0x50, 0x4E, 0x47])
    let info = NowPlayingInfo(
        title: "Cult of Shrek",
        artist: "Sounds Like A Cult",
        albumTitle: "Sounds Like A Cult",
        duration: 3600,
        elapsedTime: 120,
        playbackRate: 1.25,
        isPlaying: true,
        artwork: art
    )
    #expect(info.title == "Cult of Shrek")
    #expect(info.artist == "Sounds Like A Cult")
    #expect(info.duration == 3600)
    #expect(info.elapsedTime == 120)
    #expect(info.playbackRate == 1.25)
    #expect(info.isPlaying)
    #expect(info.artwork?.count == 4)
}

@Test func podcastSkipIntervalMatchesInAppControls() {
    #expect(AudioSessionActor.podcastSkipInterval == 15)
}

@Test func remoteCommandCasesCoverTransportSurface() {
    let commands: [RemoteCommand] = [
        .play,
        .pause,
        .togglePlayPause,
        .skipForward(AudioSessionActor.podcastSkipInterval),
        .skipBackward(AudioSessionActor.podcastSkipInterval),
        .changePlaybackPosition(42),
        .changePlaybackRate(1.5),
        .nextTrack,
        .previousTrack,
    ]
    #expect(commands.count == 9)
}
