// Public values only. The anon key is safe in the browser; RLS does the gatekeeping.
// Never put the service_role key here.
window.APP_CONFIG = {
  supabaseUrl: "https://oafrmejpwszxqbxszbjz.supabase.co",
  supabaseAnonKey: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9hZnJtZWpwd3N6eHFieHN6Ymp6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTIwMzgzOTcsImV4cCI6MjEwNzYxNDM5N30.K6PBOQv5dIdlDVXpfexaJPZpel8ahsRuXW3uMbk0GGo",
  // Default client for the calendar. Override per link with ?client=<slug>. Empty = unbranded.
  clientSlug: "delta",
};
