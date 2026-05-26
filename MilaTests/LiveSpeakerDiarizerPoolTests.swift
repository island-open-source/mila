import XCTest
@testable import Mila

/// Pure-Swift unit tests for the cosine-similarity speaker pool inside
/// `LiveSpeakerDiarizer`. No Python or pyannote involved — we feed in
/// synthetic embedding vectors and assert the pool's matching logic.
@MainActor
final class LiveSpeakerDiarizerPoolTests: XCTestCase {

    func test_cosineSimilarity_identical_vectors_is_one() {
        let v: [Float] = [1, 2, 3, 4, 5]
        XCTAssertEqual(cosineSimilarity(v, v), 1.0, accuracy: 1e-6)
    }

    func test_cosineSimilarity_orthogonal_vectors_is_zero() {
        XCTAssertEqual(cosineSimilarity([1, 0, 0], [0, 1, 0]), 0.0, accuracy: 1e-6)
    }

    func test_cosineSimilarity_handles_zero_vectors_gracefully() {
        XCTAssertEqual(cosineSimilarity([0, 0, 0], [1, 1, 1]), 0.0, accuracy: 1e-6)
    }

    func test_cosineSimilarity_handles_length_mismatch() {
        XCTAssertEqual(cosineSimilarity([1, 0], [1, 0, 0]), 0.0)
    }

    func test_assign_first_speaker_creates_SPEAKER_00() {
        let d = LiveSpeakerDiarizer()
        d.similarityThreshold = 0.7
        let id = d.assign(embedding: [1, 0, 0, 0])
        XCTAssertEqual(id, "SPEAKER_00")
    }

    func test_assign_similar_embedding_maps_to_same_speaker() {
        let d = LiveSpeakerDiarizer()
        d.similarityThreshold = 0.7
        _ = d.assign(embedding: [1, 0, 0, 0])
        // Slightly perturbed — well above the 0.7 cosine threshold.
        let id = d.assign(embedding: [0.99, 0.01, 0.01, 0.01])
        XCTAssertEqual(id, "SPEAKER_00")
    }

    func test_assign_dissimilar_embedding_creates_new_speaker() {
        let d = LiveSpeakerDiarizer()
        d.similarityThreshold = 0.7
        _ = d.assign(embedding: [1, 0, 0, 0])
        let id = d.assign(embedding: [0, 1, 0, 0])
        XCTAssertEqual(id, "SPEAKER_01")
    }

    func test_assign_two_distinct_voices_then_revisit_first() {
        let d = LiveSpeakerDiarizer()
        d.similarityThreshold = 0.7
        let a1 = d.assign(embedding: [1, 0, 0, 0])
        let b1 = d.assign(embedding: [0, 1, 0, 0])
        let a2 = d.assign(embedding: [0.95, 0.05, 0, 0])
        let b2 = d.assign(embedding: [0.05, 0.95, 0, 0])
        XCTAssertEqual(a1, "SPEAKER_00")
        XCTAssertEqual(b1, "SPEAKER_01")
        XCTAssertEqual(a2, "SPEAKER_00")
        XCTAssertEqual(b2, "SPEAKER_01")
    }

    func test_centroid_updates_pull_threshold_toward_drifting_voice() {
        let d = LiveSpeakerDiarizer()
        d.similarityThreshold = 0.75
        // First sample: pure vector along the X axis.
        _ = d.assign(embedding: [1, 0, 0, 0])
        // Drift the speaker's representation gradually. After several
        // updates the centroid should track the drift, so a vector
        // with significant Y component still matches.
        _ = d.assign(embedding: [0.85, 0.5, 0, 0])
        _ = d.assign(embedding: [0.7, 0.7, 0, 0])
        // This is far from the original [1,0,0,0] (cosine ~0.5) but
        // the centroid has drifted enough that it should match.
        let id = d.assign(embedding: [0.6, 0.8, 0, 0])
        XCTAssertEqual(id, "SPEAKER_00")
    }

    func test_higher_threshold_makes_pool_more_conservative() {
        let d = LiveSpeakerDiarizer()
        d.similarityThreshold = 0.99
        _ = d.assign(embedding: [1, 0, 0, 0])
        // A close-but-not-identical vector is rejected at threshold 0.99
        // and registers a new speaker, where it would have merged at 0.7.
        let id = d.assign(embedding: [0.95, 0.3, 0, 0])
        XCTAssertEqual(id, "SPEAKER_01")
    }
}
