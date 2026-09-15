package main

// Issue #641: get_trip (and, through it, the per-turn CURRENT TRIP STATE
// block) states "Today is day N" directly for a trip that is happening right
// now, so a nearby same-city move ("move today's museum to tomorrow") never
// requires the model to derive that day number itself from the trip's start
// date and every city's rendered leg span — the derivation that was leaking
// into replies as narrated day-to-calendar-date arithmetic.

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"
)

func TestGetTripToolStatesTodaysDayNumberForALiveTrip(t *testing.T) {
	resetDB(t)
	owner, _ := createTestUser(t, "agent@example.com")
	trip := createTestTrip(t, owner.ID, 0)

	now := time.Now()
	start := now.AddDate(0, 0, -21) // trip began 3 weeks ago
	end := now.AddDate(0, 0, 7)
	if _, err := dbPool.Exec(context.Background(),
		`UPDATE trips SET start_date = $2, end_date = $3 WHERE id = $1`,
		trip.ID, start.Format(dateLayout), end.Format(dateLayout)); err != nil {
		t.Fatalf("date fixture: %v", err)
	}

	detail, isErr := runGetTripTool(context.Background(), true, owner.ID, nil,
		[]byte(`{"trip_id":"`+trip.ID.String()+`"}`))
	if isErr {
		t.Fatalf("detail errored: %q", detail)
	}
	want := fmt.Sprintf("Today is day %d of this trip", 22)
	if !strings.Contains(detail, want) {
		t.Fatalf("get_trip did not state today's day number:\nwant substring %q\ngot:\n%s", want, detail)
	}
}

func TestGetTripToolOmitsTodaysDayNumberOutsideTheTripSpan(t *testing.T) {
	resetDB(t)
	owner, _ := createTestUser(t, "agent@example.com")

	future := createTestTrip(t, owner.ID, 0)
	now := time.Now()
	futureStart := now.AddDate(0, 0, 30)
	futureEnd := now.AddDate(0, 0, 37)
	if _, err := dbPool.Exec(context.Background(),
		`UPDATE trips SET start_date = $2, end_date = $3 WHERE id = $1`,
		future.ID, futureStart.Format(dateLayout), futureEnd.Format(dateLayout)); err != nil {
		t.Fatalf("date fixture: %v", err)
	}
	detail, isErr := runGetTripTool(context.Background(), true, owner.ID, nil,
		[]byte(`{"trip_id":"`+future.ID.String()+`"}`))
	if isErr {
		t.Fatalf("detail errored: %q", detail)
	}
	if strings.Contains(detail, "Today is day") {
		t.Fatalf("a trip that hasn't started yet should not claim a today day number:\n%s", detail)
	}

	undated := createTestTrip(t, owner.ID, 0)
	detail, isErr = runGetTripTool(context.Background(), true, owner.ID, nil,
		[]byte(`{"trip_id":"`+undated.ID.String()+`"}`))
	if isErr {
		t.Fatalf("detail errored: %q", detail)
	}
	if strings.Contains(detail, "Today is day") {
		t.Fatalf("an undated trip should not claim a today day number:\n%s", detail)
	}
}
