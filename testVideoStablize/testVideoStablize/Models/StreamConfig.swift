//
//  StreamConfig.swift
//  testVideoStablize
//
//  Created by Thinh Nguyen on 13/3/25.
//

struct StreamConfig {
    static let streamURL = URL(string: "http://192.168.1.18:81/trek_stream")!
//    static let vlcStreamURL = URL(string: "http://192.168.1.18:81/stream")!
    static let vlcStreamURL = URL(string: "https://cdn.flowplayer.com/a30bd6bc-f98b-47bc-abf5-97633d4faea0/hls/de3f6ca7-2db3-4689-8160-0f574a5996ad/playlist.m3u8")!
    static let gyroscopeURL = URL(string: "http://192.168.1.18/gyroscope")!
}
