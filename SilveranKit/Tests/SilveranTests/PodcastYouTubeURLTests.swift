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
