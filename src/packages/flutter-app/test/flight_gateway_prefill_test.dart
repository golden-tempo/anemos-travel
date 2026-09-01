import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/models/airport.dart';
import 'package:travel_route_planner/models/flight_search_request.dart';
import 'package:travel_route_planner/models/flight_search_response.dart';
import 'package:travel_route_planner/models/user.dart';
import 'package:travel_route_planner/providers/auth_provider.dart';
import 'package:travel_route_planner/providers/flights_provider.dart';
import 'package:travel_route_planner/screens/flight_search_screen.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/flights_api_service.dart';

import 'support/l10n_test_app.dart';

/// Gateway labels carry their IATA code in parentheses — "Salzburg (SZG)",
/// written by the server onto an airportless city's flight legs
/// (specs/leg-gateway-airports). The flight screen's resolver must read that
/// code straight out of the label: the fake below answers every TEXT airport
/// search with nothing, so the auto-search can only fire if the parenthesized
/// extraction worked.
class _CodeOnlyFlightsApi extends FlightsApiService {
  final List<FlightSearchRequest> requests = [];
  _CodeOnlyFlightsApi() : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<FlightSearchResponse> searchFlights(
      FlightSearchRequest request) async {
    requests.add(request);
    return const FlightSearchResponse(
        offers: [], count: 0, status: 'success', optimizeFor: 'balanced');
  }

  @override
  Future<List<Airport>> searchAirports(String query) async => [];
}

class _StubAuthNotifier extends StateNotifier<AuthState>
    implements AuthNotifier {
  _StubAuthNotifier()
      : super(AuthState(
            user: UserModel(
                id: 'u1',
                email: 't@example.com',
                displayName: 'T',
                createdAt: DateTime(2026, 1, 1)),
            initialized: true));

  @override
  void clearError() {}
  @override
  Future<bool> login(String email, String password) async => false;
  @override
  Future<bool> register(String email, String password,
          {String? displayName}) async =>
      false;
  @override
  Future<void> completeOnboarding() async {}
  @override
  Future<void> logout() async {}
  @override
  Future<void> signOutLocally() async {}
  @override
  void setUser(UserModel user) {}
  @override
  Future<void> adoptSession(String token, UserModel user) async {}
}

void main() {
  testWidgets('a gateway label resolves by its parenthesized code, no lookup',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final flights = _CodeOnlyFlightsApi();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        flightsApiServiceProvider.overrideWithValue(flights),
        authProvider.overrideWith((ref) => _StubAuthNotifier()),
      ],
      child: MaterialApp(
        localizationsDelegates: testLocalizationsDelegates,
        home: const FlightSearchScreen(
          prefillOrigin: 'Salzburg (SZG)',
          prefillDestination: 'Gothenburg (GOT)',
          prefillDepartDate: '2026-09-10',
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(flights.requests, hasLength(1),
        reason: 'the prefill auto-search fires only if both labels resolved');
    expect(flights.requests.single.origin, 'SZG');
    expect(flights.requests.single.destination, 'GOT');
  });
}
