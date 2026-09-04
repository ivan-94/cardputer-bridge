import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

class AudioCryptoMemoryPolicyTests(unittest.TestCase):
    def test_audio_has_no_cipher_or_session_key(self):
        paths = [
            "firmware/components/device_audio/device_audio.cpp",
            "firmware/main/main.cpp",
            "firmware/components/audio_transport/include/audio_packet.hpp",
            "macos/Sources/CardputerBridgeCore/AudioDatagramV2.swift",
            "macos/Sources/CardputerBridgeCore/AudioControlMessage.swift",
            "macos/Sources/CardputerBridgeApp/AudioReceiverController.swift",
        ]
        for path in paths:
            with self.subTest(path=path):
                source = (ROOT / path).read_text()
                for forbidden in ("mbedtls_", "ChaChaPoly", "AES.GCM", "SymmetricKey",
                                  "make_audio_nonce", "kAudioAuthTagBytes", "offer.key"):
                    self.assertNotIn(forbidden, source)
        cmake = (ROOT / "firmware/components/device_audio/CMakeLists.txt").read_text()
        self.assertNotIn("mbedtls", cmake)

if __name__ == "__main__":
    unittest.main()
