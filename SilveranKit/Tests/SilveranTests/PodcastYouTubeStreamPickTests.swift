import Foundation
import Testing

@testable import SilveranKit

@Test func youtubeStreamPickPrefersProgressiveMp4() throws {
    let json: [String: Any] = [
        "formatStreams": [
            [
                "url": "https://cdn.example/vid.webm",
                "container": "webm",
                "qualityLabel": "1080p",
                "type": "video/webm",
            ],
            [
                "url": "https://cdn.example/vid.mp4",
                "container": "mp4",
                "qualityLabel": "720p",
                "type": "video/mp4",
            ],
        ],
        "hlsUrl": "https://cdn.example/master.m3u8",
    ]
    let data = try JSONSerialization.data(withJSONObject: json)
    let pick = try #require(PodcastYouTubeStreamPicker.pick(from: data))
    #expect(pick.url.absoluteString == "https://cdn.example/vid.mp4")
    #expect(pick.kind == .progressive)
}

@Test func youtubeStreamPickFallsBackToHls() throws {
    let json: [String: Any] = [
        "formatStreams": [] as [Any],
        "hlsUrl": "https://cdn.example/live.m3u8",
    ]
    let data = try JSONSerialization.data(withJSONObject: json)
    let pick = try #require(PodcastYouTubeStreamPicker.pick(from: data))
    #expect(pick.url.absoluteString == "https://cdn.example/live.m3u8")
    #expect(pick.kind == .hls)
}

@Test func youtubeStreamPickThinNasUrl() throws {
    let json: [String: Any] = ["url": "https://nas.local/out.mp4", "mime": "video/mp4"]
    let data = try JSONSerialization.data(withJSONObject: json)
    let pick = try #require(PodcastYouTubeStreamPicker.pick(from: data))
    #expect(pick.url.absoluteString == "https://nas.local/out.mp4")
    #expect(pick.kind == .progressive)
}

@Test func youtubeStreamPickPipedMuxedMp4() throws {
    let json: [String: Any] = [
        "videoStreams": [
            [
                "url": "https://piped.example/a.mp4",
                "videoOnly": true,
                "height": 1080,
                "mimeType": "video/mp4",
            ],
            [
                "url": "https://piped.example/mux.mp4",
                "videoOnly": false,
                "height": 720,
                "mimeType": "video/mp4",
            ],
        ]
    ]
    let data = try JSONSerialization.data(withJSONObject: json)
    let pick = try #require(PodcastYouTubeStreamPicker.pick(from: data))
    #expect(pick.url.absoluteString == "https://piped.example/mux.mp4")
}

@Test func youtubeStreamPickResolvesRelativeAgainstBase() throws {
    let json: [String: Any] = [
        "formatStreams": [
            [
                "url": "/latest_version?id=abc&itag=18",
                "container": "mp4",
                "qualityLabel": "360p",
                "type": "video/mp4",
            ]
        ]
    ]
    let data = try JSONSerialization.data(withJSONObject: json)
    let base = URL(string: "http://192.168.1.2:3000")!
    let pick = try #require(PodcastYouTubeStreamPicker.pick(from: data, baseURL: base))
    #expect(pick.url.absoluteString.hasPrefix("http://192.168.1.2:3000/latest_version"))
}

@Test func youtubeStreamPickEmptyReturnsNil() {
    let data = Data("{}".utf8)
    #expect(PodcastYouTubeStreamPicker.pick(from: data) == nil)
}
