import Foundation
@testable import LTXVideoGeneratorCore

func runAcceptanceTests(_ t: TestKit) {
    t.suite("Acceptance - Local AI Director grounding") {
        var appearance = OpeningReferenceAppearance()
        appearance.sceneEnvironment = "night train platform"
        appearance.sceneLighting = "dim night lighting"
        appearance.subjectState = "standing near a train"
        appearance.keyObjects = "blue suitcase, train visible"
        appearance.clothingDescription = "red coat"
        appearance.faceVisible = true
        appearance.subjectCount = 1

        let bible = OpeningReferenceSync.seedBible(from: appearance, existing: CharacterBible())
        
        let director = StoryboardDirector()
        let sem = DispatchSemaphore(value: 0)
        
        Task {
            print("\n--- BRIEF A: 'She suddenly starts running.' ---")
            do {
                let (projectA, _, _) = try await director.makeProject(
                    title: "Test A",
                    brief: "She suddenly starts running.",
                    characterBible: bible,
                    openingSceneEvidence: appearance
                )
                print("Test A Initial state location: \(projectA.shots.first?.title ?? "")")
                for (i, shot) in projectA.shots.enumerated() {
                    print("Test A Shot \(i+1): \(shot.title)")
                }
            } catch {
                print("Test A Error: \(error)")
            }
            
            print("\n--- BRIEF B: 'She boards the train and later arrives at the seaside.' ---")
            do {
                let (projectB, _, _) = try await director.makeProject(
                    title: "Test B",
                    brief: "She boards the train and later arrives at the seaside.",
                    characterBible: bible,
                    openingSceneEvidence: appearance
                )
                print("Test B Initial state location: \(projectB.shots.first?.title ?? "")")
                for (i, shot) in projectB.shots.enumerated() {
                    print("Test B Shot \(i+1): \(shot.title)")
                }
            } catch {
                print("Test B Error: \(error)")
            }
            sem.signal()
        }
        sem.wait()
    }
}
