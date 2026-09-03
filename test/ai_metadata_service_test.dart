import 'dart:convert';

import 'package:c2pa_viewer/src/models.dart';
import 'package:c2pa_viewer/src/services/ai_metadata_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses trusted signer, model, history, and validation checks', () {
    final source = jsonEncode(<String, Object>{
      'active_manifest': 'active',
      'manifests': <String, Object>{
        'active': <String, Object>{
          'title': 'result.png',
          'claim_version': 2,
          'signature_info': <String, Object>{
            'issuer': 'Example Studio',
            'alg': 'PS256',
          },
          'ingredients': <Object>[
            <String, Object>{
              'title': 'source.png',
              'active_manifest': 'source',
            },
          ],
          'assertions': <Object>[
            <String, Object>{
              'label': 'c2pa.actions.v2',
              'data': <String, Object>{
                'actions': <Object>[
                  <String, Object>{
                    'action': 'c2pa.edited',
                    'softwareAgent': <String, Object>{
                      'name': 'Example AI Studio',
                      'version': '1.0.0',
                    },
                    'parameters': <String, Object>{
                      'model_name': 'example-model',
                      'digital_source_type':
                          'http://cv.iptc.org/newscodes/digitalsourcetype/trainedAlgorithmicMedia',
                    },
                  },
                ],
              },
            },
          ],
        },
        'source': <String, Object>{'title': 'source.png'},
      },
      'validation_results': <String, Object>{
        'activeManifest': <String, Object>{
          'success': <Object>[
            <String, Object>{'code': 'claimSignature.validated'},
            <String, Object>{'code': 'signingCredential.trusted'},
          ],
        },
      },
      'validation_status': <Object>[
        <String, Object>{'code': 'signingCredential.untrusted'},
      ],
    });

    final metadata = AiMetadataService.parseC2paJson(source);

    expect(metadata.c2paStatus, C2paStatus.conformant);
    expect(metadata.vendor, 'Example Studio');
    expect(metadata.model, 'example-model');
    expect(metadata.c2paReport?.manifests, hasLength(2));
    expect(metadata.c2paReport?.activeManifest?.claimVersion, 'v2');
    expect(metadata.c2paReport?.activeManifest?.contentType, 'AI-generated');
    expect(metadata.c2paReport?.activeManifest?.software, 'Example AI Studio');
    expect(
      metadata.c2paReport?.activeManifest?.ingredients.single.manifestLabel,
      'source',
    );
    expect(metadata.c2paReport?.passedCheckCount, 2);
    expect(metadata.c2paReport?.failedCheckCount, 1);
    expect(
      metadata.c2paReport?.validationEntries.map((entry) => entry.code),
      <String>[
        'signingCredential.untrusted',
        'claimSignature.validated',
        'signingCredential.trusted',
      ],
    );
  });

  test('distinguishes untrusted and invalid credentials', () {
    String sourceFor(String code) => jsonEncode(<String, Object>{
      'active_manifest': 'active',
      'manifests': <String, Object>{
        'active': <String, Object>{
          'signature_info': <String, Object>{'issuer': 'Example'},
        },
      },
      'validation_status': <Object>[
        <String, Object>{'code': code},
      ],
      'validation_results': <String, Object>{
        'activeManifest': <String, Object>{
          'success': <Object>[
            <String, Object>{'code': 'claimSignature.validated'},
          ],
        },
      },
    });

    expect(
      AiMetadataService.parseC2paJson(
        sourceFor('signingCredential.untrusted'),
      ).c2paStatus,
      C2paStatus.untrusted,
    );
    expect(
      AiMetadataService.parseC2paJson(
        sourceFor('claimSignature.mismatch'),
      ).c2paStatus,
      C2paStatus.invalid,
    );
  });
}
