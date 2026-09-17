import Foundation
import Testing

@testable import SilveranKit

@Test func youtubeExtractFromWatchURL() {
    let url = PodcastYouTubeURL.extract(from: ["https://www.youtube.com/watch?v=dQw4w9WgXcQ"])
    #expect(url?.absoluteString == "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
}

@Test func youtubeExtractFromShortLinkInHTML() {
    let html = #"<p>Watch <a href="https://youtu.be/dQw4w9WgXcQ">here</a></p>"#
    let url = PodcastYouTubeURL.extract(from: [html])
    #expect(url?.absoluteString == "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
}

@Test func youtubeExtractIgnoresNonYouTube() {
    let url = PodcastYouTubeURL.extract(from: [
        "https://example.com/video.mp4",
        "No links here",
    ])
    #expect(url == nil)
}

@Test func youtubeDetectsEmbedAndShorts() {
    #expect(PodcastYouTubeURL.isYouTubeURL(URL(string: "https://www.youtube.com/embed/dQw4w9WgXcQ")!))
    #expect(PodcastYouTubeURL.isYouTubeURL(URL(string: "https://www.youtube.com/shorts/dQw4w9WgXcQ")!))
    #expect(!PodcastYouTubeURL.isYouTubeURL(URL(string: "https://vimeo.com/123")!))
}

@Test func youtubeRejectsChannelAndHandleURLs() {
    let rejected = [
        "https://www.youtube.com/channel/UC_x5XG1OV2P6uZZ5FSM9Ttw",
        "https://www.youtube.com/@SomeHandle",
        "https://www.youtube.com/user/SomeUser",
        "https://www.youtube.com/c/SomeChannel",
        "https://www.youtube.com/playlist?list=PLrAXtmRdnEQy6nuLMHjMZOz59Oq8JeQ",
        "https://m.youtube.com/@SomeHandle/videos",
    ]
    for raw in rejected {
        #expect(PodcastYouTubeURL.extract(from: [raw]) == nil, "should reject \(raw)")
        let url = URL(string: raw)!
        #expect(PodcastYouTubeURL.videoID(from: url) == nil, "videoID nil for \(raw)")
    }
}

@Test func youtubeAcceptsYoutuBeWithShareParam() {
    let url = PodcastYouTubeURL.extract(from: ["https://youtu.be/iURXlAXLIVA?si=abc123"])
    #expect(url?.absoluteString == "https://www.youtube.com/watch?v=iURXlAXLIVA")
    #expect(PodcastYouTubeURL.videoID(from: url!) == "iURXlAXLIVA")
}

@Test func youtubeAcceptsWatchWithV() {
    let url = PodcastYouTubeURL.extract(from: [
        "https://www.youtube.com/watch?v=iURXlAXLIVA&feature=share"
    ])
    #expect(url?.absoluteString == "https://www.youtube.com/watch?v=iURXlAXLIVA")
}

@Test func youtubeAcceptsEmbedShortsLive() {
    #expect(
        PodcastYouTubeURL.extract(from: ["https://www.youtube.com/embed/iURXlAXLIVA"])?
            .absoluteString == "https://www.youtube.com/watch?v=iURXlAXLIVA"
    )
    #expect(
        PodcastYouTubeURL.extract(from: ["https://www.youtube.com/shorts/iURXlAXLIVA"])?
            .absoluteString == "https://www.youtube.com/watch?v=iURXlAXLIVA"
    )
    #expect(
        PodcastYouTubeURL.extract(from: ["https://www.youtube.com/live/iURXlAXLIVA"])?
            .absoluteString == "https://www.youtube.com/watch?v=iURXlAXLIVA"
    )
}

@Test func youtubeMixedCandidatesPreferVideoOverChannel() {
    // Channel item link first must not win over a real watch URL later in the scan.
    let url = PodcastYouTubeURL.extract(from: [
        "https://www.youtube.com/@SomeShow",
        "https://www.youtube.com/channel/UC_x5XG1OV2P6uZZ5FSM9Ttw",
        #"<p>Episode: <a href="https://youtu.be/iURXlAXLIVA?si=x">watch</a></p>"#,
    ])
    #expect(url?.absoluteString == "https://www.youtube.com/watch?v=iURXlAXLIVA")
}
