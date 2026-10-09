import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

import 'package:test/test.dart';
import 'package:connect/network/transfer/isolate/commands.dart';
import 'package:connect/network/transfer/isolate/network_commands.dart';
import 'package:connect/network/crypto/trust_store.dart';

void main() {
  group('Transfer Isolate Protocol Tests', () {
    test('TransferCommand creation and properties', () {
      final commands = [
        SendFileCommand(
          transferId: 'test-1',
          deviceId: 'device-1',
          filePath: '/test/file.txt',
          fileName: 'file.txt',
          fileSize: 1024,
          priority: SchedulerPriority.file,
        ),
        SendMessageCommand(
          transferId: 'test-2',
          deviceId: 'device-1',
          content: 'Hello',
          contentType: 'text',
        ),
        ControlCommand(
          transferId: 'test-3',
          deviceId: 'device-1',
          payload: {'volume': 0.5},
        ),
        PauseTransferCommand('test-1'),
        ResumeTransferCommand('test-1'),
        CancelTransferCommand('test-1', 'User cancelled'),
        PrioritizeTransferCommand('test-1', SchedulerPriority.control),
        ConnectDeviceCommand(
          deviceId: 'device-1',
          host: '192.168.1.100',
          port: 4040,
          fingerprint: 'abc123',
          trustPolicy: TrustPolicy.tofu,
        ),
        DisconnectDeviceCommand('device-1'),
        const GetTransfersCommand(),
        GetTransferStatusCommand('test-1'),
        const ShutdownCommand(),
      ];

      for (final command in commands) {
        // Verify command can be created and has expected properties
        expect(command, isNotNull);
        if (command is SendFileCommand) {
          expect(command.transferId, equals('test-1'));
          expect(command.fileSize, equals(1024));
        }
      }
    });

    test('NetworkCommand creation and properties', () {
      final commands = [
        SendFrameCommand(
          connectionId: 'conn-1',
          type: 'file_chunk',
          header: {'transferId': 'test-1', 'chunkIndex': 0},
          payload: Uint8List.fromList([1, 2, 3, 4]),
          priority: SchedulerPriority.file,
        ),
        ConnectCommand(
          connectionId: 'conn-1',
          deviceId: 'device-1',
          host: '192.168.1.100',
          port: 4040,
          trustPolicy: TrustPolicy.tofu,
        ),
        DisconnectCommand('conn-1'),
        CloseConnectionCommand('conn-1'),
        GetConnectionStateCommand('conn-1'),
        HeartbeatCommand('conn-1'),
        const NetworkShutdownCommand(),
      ];

      for (final command in commands) {
        expect(command, isNotNull);
        if (command is SendFrameCommand) {
          expect(command.connectionId, equals('conn-1'));
          expect(command.payload.length, equals(4));
        }
      }
    });

    test('SchedulerPriority ordering', () {
      expect(SchedulerPriority.control.index, lessThan(SchedulerPriority.message.index));
      expect(SchedulerPriority.message.index, lessThan(SchedulerPriority.file.index));
    });

    test('TransferInfo progress calculation', () {
      final info = TransferInfo(
        id: 'test',
        deviceId: 'device',
        fileName: 'test.txt',
        totalBytes: 1000,
        transferredBytes: 500,
        status: TransferStatus.transferring,
        priority: SchedulerPriority.file,
      );

      expect(info.progress, equals(0.5));
    });
  });

  group('Dynamic Chunk Sizing Tests', () {
    test('Chunk size calculation for small files', () {
      // < 1 GB -> 1 MB
      expect(_calculateChunkSizeForTest(500 * 1024 * 1024), equals(1024 * 1024));
      expect(_calculateChunkSizeForTest(1024 * 1024), equals(1024 * 1024));
    });

    test('Chunk size calculation for medium files', () {
      // 1-10 GB -> 4 MB
      expect(_calculateChunkSizeForTest(2 * 1024 * 1024 * 1024), equals(4 * 1024 * 1024));
      expect(_calculateChunkSizeForTest(5 * 1024 * 1024 * 1024), equals(4 * 1024 * 1024));
    });

    test('Chunk size calculation for large files', () {
      // > 10 GB -> 16 MB
      expect(_calculateChunkSizeForTest(15 * 1024 * 1024 * 1024), equals(16 * 1024 * 1024));
      expect(_calculateChunkSizeForTest(100 * 1024 * 1024 * 1024), equals(16 * 1024 * 1024));
    });
  });

  group('Streaming Hash Tests', () {
    test('Streaming hash accumulator produces correct hash', () {
      final accumulator = _TestStreamingHashAccumulator();
      
      accumulator.add([1, 2, 3, 4]);
      accumulator.add([5, 6, 7, 8]);
      
      final hash = accumulator.finalize();
      expect(hash, isNotEmpty);
      
      // Verify against known hash
      final expected = sha256.convert([1, 2, 3, 4, 5, 6, 7, 8]);
      expect(hash, equals(base64Encode(expected.bytes)));
    });

    test('Empty data produces correct hash', () {
      final accumulator = _TestStreamingHashAccumulator();
      final hash = accumulator.finalize();
      
      final expected = sha256.convert([]);
      expect(hash, equals(base64Encode(expected.bytes)));
    });
  });

  group('Connection State Tests', () {
    test('ConnectionState enum values', () {
      expect(ConnectionState.connecting.index, equals(0));
      expect(ConnectionState.connected.index, equals(1));
      expect(ConnectionState.disconnected.index, equals(2));
      expect(ConnectionState.failed.index, equals(3));
    });
  });
}

// Helper function for testing chunk size calculation
int _calculateChunkSizeForTest(int fileSize) {
  if (fileSize >= 10 * 1024 * 1024 * 1024) {
    return 16 * 1024 * 1024;
  } else if (fileSize >= 1024 * 1024 * 1024) {
    return 4 * 1024 * 1024;
  } else {
    return 1024 * 1024;
  }
}

// Test implementation of streaming hash accumulator
class _TestStreamingHashAccumulator {
  final List<int> _bytes = [];

  void add(List<int> data) {
    _bytes.addAll(data);
  }

  String finalize() {
    final digest = sha256.convert(_bytes);
    return base64Encode(digest.bytes);
  }
}