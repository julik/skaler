require "test_helper"

class Skaler::IngressProfileTest < Skaler::TestCase
  setup do
    @profile = Skaler::IngressProfile.from_csv(
      example_path("enqueues_per_minute.csv"),
      durations_csv: example_path("job_durations.csv")
    )
  end

  test "builds one job type per CSV column" do
    assert_equal %i[sync_mailbox_job process_webhook_job fetch_message_job generate_digest_job send_notification_job],
      @profile.job_types.keys
  end

  test "max_time covers every minute row" do
    assert_equal 240 * 60, @profile.max_time
  end

  test "schedule skips empty cells and offsets each row by a minute" do
    schedule = @profile.arrival_process_config[:schedule]
    digest_minutes = schedule.select { |_, _, type| type == :generate_digest_job }.map(&:first)

    assert_equal 12, digest_minutes.size # the 08:00 digest spike only
    assert_equal 120 * 60.0, digest_minutes.min
  end

  test "uses durations from the durations CSV when the class matches" do
    duration = @profile.job_types[:generate_digest_job].duration
    assert_kind_of Skaler::Distribution, duration

    rng = Random.new(1)
    samples = 2000.times.map { duration.call(rng) }
    # Far above the 0.5-2s default. Not exactly 4.2s - Distribution folds negative draws above the mean
    assert_operator samples.sum / samples.size, :>, 4.0
  end

  test "falls back to the default duration for classes missing from the durations CSV" do
    profile = Skaler::IngressProfile.from_csv(example_path("enqueues_per_minute.csv"))
    assert_same Skaler::IngressProfile::DEFAULT_DURATION, profile.job_types[:sync_mailbox_job].duration
  end
end
