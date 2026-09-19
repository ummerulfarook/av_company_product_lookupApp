import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ApiService {
  // Use the PC's local IP address so the physical Android device can connect over Wi-Fi
  static const String baseUrl =
      kIsWeb ? 'http://127.0.0.1:8000/api' : 'http://192.168.0.118:8000/api';
  final storage = const FlutterSecureStorage();

  // ── In-memory product cache ──────────────────────────────────────────────
  // Populated on first successful fetch; persists for the app session.
  static List<Map<String, dynamic>>? _allProductsCache;

  /// Call this to clear the cache (e.g. after logout).
  static void clearProductCache() => _allProductsCache = null;

  Future<bool> login(String username, String password) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/token/'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'username': username, 'password': password}),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        await storage.write(key: 'access_token', value: data['access']);
        await storage.write(key: 'refresh_token', value: data['refresh']);
        await storage.write(
            key: 'login_time', value: DateTime.now().toIso8601String());
        return true;
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  bool _isTokenExpired(String token) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return true;
      final payload = parts[1];
      
      // Normalize base64 URL string
      String normalized = payload;
      int mod = payload.length % 4;
      if (mod > 0) {
        normalized += '=' * (4 - mod);
      }
      
      final String decoded = utf8.decode(base64Url.decode(normalized));
      final Map<String, dynamic> claims = jsonDecode(decoded);
      if (claims.containsKey('exp')) {
        final int exp = claims['exp'];
        final DateTime expTime = DateTime.fromMillisecondsSinceEpoch(exp * 1000);
        return DateTime.now().isAfter(expTime.subtract(const Duration(minutes: 1)));
      }
      return true;
    } catch (_) {
      return true;
    }
  }

  Future<bool> _refreshToken() async {
    try {
      final refresh = await storage.read(key: 'refresh_token');
      if (refresh == null || refresh.isEmpty) return false;

      final response = await http.post(
        Uri.parse('$baseUrl/token/refresh/'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'refresh': refresh}),
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final access = data['access'];
        if (access != null) {
          await storage.write(key: 'access_token', value: access);
          if (data['refresh'] != null) {
            await storage.write(key: 'refresh_token', value: data['refresh']);
          }
          return true;
        }
      } else if (response.statusCode == 401 || response.statusCode == 403) {
        throw 'unauthorized';
      }
      return false;
    } catch (e) {
      if (e == 'unauthorized') {
        rethrow;
      }
      return false;
    }
  }

  Future<String?> _getValidToken() async {
    String? token = await storage.read(key: 'access_token');
    if (token == null) return null;

    if (_isTokenExpired(token)) {
      try {
        final success = await _refreshToken();
        if (success) {
          token = await storage.read(key: 'access_token');
        }
      } catch (e) {
        await logout();
        return null;
      }
    }
    return token;
  }

  /// Fetches all products into the cache (hits backend only once per session).
  Future<List<Map<String, dynamic>>?> _fetchAllProducts(String token) async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/products/?query='),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
      ).timeout(const Duration(seconds: 10)); // Timeout for offline detection

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data is List) {
          _allProductsCache = List<Map<String, dynamic>>.from(data);

          // Save to local storage for offline use
          try {
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString(
                'cached_products', jsonEncode(_allProductsCache));
          } catch (_) {}

          return _allProductsCache;
        }
      }
    } catch (e) {
      // If server is unavailable, fallback to SharedPreferences
      try {
        final prefs = await SharedPreferences.getInstance();
        final cachedData = prefs.getString('cached_products');
        if (cachedData != null) {
          final data = jsonDecode(cachedData);
          if (data is List) {
            _allProductsCache = List<Map<String, dynamic>>.from(data);
            return _allProductsCache;
          }
        }
      } catch (_) {}
    }
    return null;
  }

  Future<List<Map<String, dynamic>>?> searchProducts({String? query, String? code}) async {
    try {
      final token = await _getValidToken();
      if (token == null) return null;

      final isQueryEmpty = query == null || query.trim().isEmpty;
      final isCodeEmpty = code == null || code.trim().isEmpty;

      // ── Both empty: just show the cached initial list ───────────────────
      if (isQueryEmpty && isCodeEmpty) {
        if (_allProductsCache != null) return _allProductsCache;
        return await _fetchAllProducts(token); // first load — hits backend once
      }

      // Try hitting the backend first
      try {
        final Map<String, String> queryParams = {};
        if (!isQueryEmpty) queryParams['query'] = query.trim();
        if (!isCodeEmpty) queryParams['code'] = code.trim();

        final uri = Uri.parse('$baseUrl/products/').replace(queryParameters: queryParams);
        final response = await http.get(
          uri,
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
        ).timeout(const Duration(seconds: 10));

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          if (data is List) {
            final results = List<Map<String, dynamic>>.from(data);
            // Merge results into cache to avoid future backend calls
            if (results.isNotEmpty && _allProductsCache != null) {
              final existingCodes =
                  _allProductsCache!.map((p) => p['product_code']).toSet();
              bool cacheUpdated = false;
              for (final r in results) {
                if (!existingCodes.contains(r['product_code'])) {
                  _allProductsCache!.add(r);
                  cacheUpdated = true;
                }
              }
              if (cacheUpdated) {
                try {
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setString(
                      'cached_products', jsonEncode(_allProductsCache));
                } catch (_) {}
              }
            }
            return results;
          }
        }
      } catch (e) {
        // Backend request failed (e.g. offline). Fallback to searching the local cache.
      }

      // Offline Fallback: Check local cache
      if (_allProductsCache == null) {
        try {
          final prefs = await SharedPreferences.getInstance();
          final cachedData = prefs.getString('cached_products');
          if (cachedData != null) {
            final data = jsonDecode(cachedData);
            if (data is List) {
              _allProductsCache = List<Map<String, dynamic>>.from(data);
            }
          }
        } catch (_) {}
      }

      List<Map<String, dynamic>> localResults = [];
      if (_allProductsCache != null) {
        if (!isCodeEmpty) {
          final c = code.trim().toLowerCase();
          localResults = _allProductsCache!
              .where((p) => p['product_code']?.toString().toLowerCase().contains(c) ?? false)
              .toList();
          localResults.sort((a, b) {
            final aCode = a['product_code']?.toString().toLowerCase() ?? '';
            final bCode = b['product_code']?.toString().toLowerCase() ?? '';
            if (aCode == c && bCode != c) return -1;
            if (bCode == c && aCode != c) return 1;
            if (aCode.startsWith(c) && !bCode.startsWith(c)) return -1;
            if (bCode.startsWith(c) && !aCode.startsWith(c)) return 1;
            return aCode.length.compareTo(bCode.length);
          });
        } else if (!isQueryEmpty) {
          final q = query.trim().toLowerCase();
          localResults = _allProductsCache!
              .where((p) => p['name']?.toString().toLowerCase().contains(q) ?? false)
              .toList();
          localResults.sort((a, b) {
            final aName = a['name']?.toString().toLowerCase() ?? '';
            final bName = b['name']?.toString().toLowerCase() ?? '';
            if (aName == q && bName != q) return -1;
            if (bName == q && aName != q) return 1;
            if (aName.startsWith(q) && !bName.startsWith(q)) return -1;
            if (bName.startsWith(q) && !aName.startsWith(q)) return 1;
            return aName.compareTo(bName);
          });
        }
      }

      return localResults;
    } catch (e) {
      return null;
    }
  }

  Future<bool> register(String name, String username, String role,
      String password, String phone, String email) async {
    try {
      final parts = name.split(' ');
      final firstName = parts.isNotEmpty ? parts.first : '';
      final lastName = parts.length > 1 ? parts.sublist(1).join(' ') : '';

      final response = await http.post(
        Uri.parse('$baseUrl/register/'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'username': username,
          'password': password,
          'email': email,
          'first_name': firstName,
          'last_name': lastName,
          'role': role,
          'phone_number': phone,
        }),
      );
      if (response.statusCode == 201) return true;
      return false;
    } catch (e) {
      return false;
    }
  }

  // ── In-memory profile cache ──────────────────────────────────────────────
  static Map<String, dynamic>? _profileCache;

  /// Call this to clear the profile cache (e.g. on logout or update).
  static void clearProfileCache() => _profileCache = null;

  Future<Map<String, dynamic>?> getProfile({bool forceRefresh = false}) async {
    try {
      if (forceRefresh || _profileCache == null) {
        final token = await _getValidToken();
        if (token == null) return null;

        try {
          final response = await http.get(
            Uri.parse('$baseUrl/profile/'),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
          ).timeout(const Duration(seconds: 10));

          if (response.statusCode == 200) {
            _profileCache = jsonDecode(response.body);

            // If the account is restricted (custom flag), don't mask it with cache
            if (_profileCache?['is_active'] == false) {
              // We keep it in cache but we'll handle redirection in the UI
            }

            try {
              final prefs = await SharedPreferences.getInstance();
              await prefs.setString(
                  'cached_profile', jsonEncode(_profileCache));
            } catch (_) {}
          } else if (response.statusCode == 401 || response.statusCode == 403) {
            // User was likely deleted or system-disabled
            await logout();
            return null;
          } else {
            throw Exception('Server returned ${response.statusCode}');
          }
        } catch (e) {
          // If server is unavailable, fallback to SharedPreferences
          try {
            final prefs = await SharedPreferences.getInstance();
            final cachedProfile = prefs.getString('cached_profile');
            if (cachedProfile != null) {
              _profileCache = jsonDecode(cachedProfile);
            } else {
              return null;
            }
          } catch (_) {
            return null;
          }
        }
      }

      // Inject dynamically calculated session hours
      if (_profileCache != null) {
        final loginTimeStr = await storage.read(key: 'login_time');
        if (loginTimeStr != null) {
          try {
            final loginTime = DateTime.parse(loginTimeStr);
            final diff = DateTime.now().difference(loginTime);
            // using inSeconds for exact granularity, 2 decimal places to capture minutes cleanly
            _profileCache!['hours_logged'] =
                (diff.inSeconds / 3600.0).toStringAsFixed(2);
          } catch (e) {
            // fallback if parsing fails
          }
        }
      }

      return _profileCache;
    } catch (e) {
      return null;
    }
  }

  Future<bool> updateProfile(Map<String, dynamic> data) async {
    try {
      final token = await _getValidToken();
      if (token == null) return false;

      final response = await http.patch(
        Uri.parse('$baseUrl/profile/'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(data),
      );
      if (response.statusCode == 200) {
        clearProfileCache(); // Refresh on next fetch
        return true;
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  Future<bool> updateProfilePhoto(String imagePath) async {
    try {
      final token = await _getValidToken();
      if (token == null) return false;

      final request =
          http.MultipartRequest('PATCH', Uri.parse('$baseUrl/profile/'));
      request.headers['Authorization'] = 'Bearer $token';

      if (kIsWeb) {
        // On web, paths are blob URLs, so we fetch bytes directly
        final response = await http.get(Uri.parse(imagePath));
        final bytes = response.bodyBytes;
        request.files.add(http.MultipartFile.fromBytes(
          'profile_photo',
          bytes,
          filename: 'profile_photo.jpg',
        ));
      } else {
        request.files
            .add(await http.MultipartFile.fromPath('profile_photo', imagePath));
      }

      final response = await request.send();
      if (response.statusCode == 200) {
        clearProfileCache(); // Refresh on next fetch
        return true;
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  Future<void> incrementSearchCount() async {
    try {
      final token = await _getValidToken();
      if (token == null) return;
      await http.post(
        Uri.parse('$baseUrl/profile/increment-search/'),
        headers: {'Authorization': 'Bearer $token'},
      );
      clearProfileCache(); // Ensure next visit shows updated count
    } catch (e) {
      // Ignore errors for background sync
    }
  }

  Future<void> logout() async {
    await storage.delete(key: 'access_token');
    await storage.delete(key: 'refresh_token');
    clearProfileCache();
    clearProductCache();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('cached_products');
      await prefs.remove('cached_profile');
    } catch (_) {}
  }

  Future<void> forgotPassword(String email) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/auth/forgot-password/'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'email': email}),
      );
      if (response.statusCode == 200) return;

      final Map<String, dynamic> data = jsonDecode(response.body);
      throw Exception(data['error'] ?? 'Failed to process request');
    } catch (e) {
      if (e is Exception) rethrow;
      throw Exception('Server unreachable. Please try again later.');
    }
  }

  Future<void> verifyOtp(String email, String otp) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/auth/verify-otp/'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'email': email, 'otp': otp}),
      );
      if (response.statusCode == 200) return;
      
      final Map<String, dynamic> data = jsonDecode(response.body);
      throw Exception(data['error'] ?? 'Failed to verify OTP');
    } catch (e) {
      if (e is Exception) rethrow;
      throw Exception('Server unreachable. Please try again later.');
    }
  }

  Future<bool> resetPassword(
      String email, String otp, String newPassword) async {
    final response = await http.post(
      Uri.parse('$baseUrl/auth/reset-password/'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'email': email,
        'otp': otp,
        'password': newPassword,
      }),
    );
    return response.statusCode == 200;
  }

  Future<String?> changePassword(String oldPassword, String newPassword) async {
    final token = await _getValidToken();
    if (token == null) return 'Not authenticated';

    final response = await http.post(
      Uri.parse('$baseUrl/auth/change-password/'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({
        'old_password': oldPassword,
        'new_password': newPassword,
      }),
    );
    if (response.statusCode == 200) return null;
    try {
      final data = jsonDecode(response.body);
      return data['error'] ?? 'Failed to change password';
    } catch (_) {
      return 'Failed to change password';
    }
  }
}
