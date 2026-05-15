import 'package:flutter/material.dart'; //access to all flutter widgets
//initialize firebase and handle user auth (email/password , google)
import 'package:firebase_core/firebase_core.dart'; 
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;  // send http requests to backend
import 'dart:convert'; //used for converting between dart and JSON 
import 'dart:io'; //work with files on the phone (used for profile photo)
import 'package:permission_handler/permission_handler.dart'; //ask user for permissions (notifications)
import 'package:flutter_local_notifications/flutter_local_notifications.dart'; //shows notifications
import 'package:shared_preferences/shared_preferences.dart'; //used to save data locally 
import 'package:image_picker/image_picker.dart'; //open camera and gallery (for pfp)

import 'firebase_options.dart'; //firebase keys

// entry point (app starts here)
void main() async {
  WidgetsFlutterBinding.ensureInitialized(); //ensure flutter is fully initialized
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await NotificationService.init();
  runApp(const ThriveApp()); //start the app 
}

// color palette , so we can reuse colors (cleaner code, consistent ui)
const Color kDarkGreen  = Color(0xFF2D6A4F);
const Color kMedGreen   = Color(0xFF4A7C6F);
const Color kLightGreen = Color(0xFFB2C5BA);
const Color kCardGreen  = Color(0xFFBEC6BA);

//Backend URL
const String kApiBaseUrl = 'http://192.168.1.104:8000';  //port 8000 for FastApi

//chat error message
const String kChatErrorFallback =
    "Sorry, I couldn't get a response. Please try again.";

//sharedPreferences keys to save local data
const String kPrefHabits        = 'habits_json';
const String kPrefTransactions  = 'transactions_json';
const String kPrefWellness      = 'wellness_json';
const String kPrefCycleEnabled  = 'cycle_enabled';
const String kPrefMenstrualD    = 'menstrual_days';
const String kPrefCycleDays     = 'cycle_days';
const String kPrefLastPeriod    = 'last_period_start';
const String kPrefNotifications = 'notifications_enabled';
const String kPrefChatHistory   = 'chat_history';
const String kPrefChatDate      = 'chat_history_date';
const String kPrefProfilePhoto  = 'profile_photo_path';

// NOTIFICATION SERVICE
class NotificationService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
//set up notifcations for android and ios
  static Future<void> init() async {
    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    const settings =
        InitializationSettings(android: androidSettings, iOS: iosSettings);
    await _plugin.initialize(settings); //start the pluggin
  }
//permission to allow notifications
  static Future<bool> requestPermission() async {
    final status = await Permission.notification.request();
    return status.isGranted;
  }
// check if permission already granted
  static Future<bool> hasPermission() async {
    return await Permission.notification.isGranted;
  }

  static Future<void> showNotification({
    //parameters for notifications
    required int id,
    required String title,
    required String body,
  }) async {
    const androidDetails = AndroidNotificationDetails(
      'thrive_channel',
      'Thrive Reminders',
      channelDescription: 'Daily wellness and habit reminders',
      importance: Importance.high, //make notification highly visible (popup)
      priority: Priority.high, //show immediately
    );
    const details = NotificationDetails(
      android: androidDetails,
      iOS: DarwinNotificationDetails(),
    );
    await _plugin.show(id, title, body, details); //display the notification
  }
//cancel/remove notification
  static Future<void> cancel(int id) => _plugin.cancel(id);
}

// AI service (handle communication with backend)
class AiService {
  static Future<String?> getInsight(String prompt) async {
    const maxRetries = 3; //retry logic
    int attempt = 0;

    while (attempt < maxRetries) {
      attempt++;
      try {
        debugPrint('[AiService] insight attempt $attempt of $maxRetries');
        //send request to get insight
        final response = await http
            .post(
              Uri.parse('$kApiBaseUrl/insight'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'prompt': prompt}), //convert to json
            )
            //set timeout to prevent the app from freezing
            .timeout(
              const Duration(seconds: 30),
              onTimeout: () {
                debugPrint('[AiService] insight request timed out');
                return http.Response('{"result": null}', 408); //408 (timeout)
              },
            );
// for debugging to check the console and look exactly what status code came back from the server
        debugPrint('[AiService] insight response status: ${response.statusCode}');
        // handle the response
        // 200 = success
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body); //convert json back to dart
          return data['result'] as String?; // return data as string
        }
        // 429 = too many requests
        //make it wait before it tries again
        if (response.statusCode == 429 && attempt < maxRetries) {
          final waitSeconds = _backoffSeconds(attempt);
          debugPrint('[AiService] 429 received — waiting ${waitSeconds}s before retry');
          await Future.delayed(Duration(seconds: waitSeconds));
          continue;
        }
//show a message to the user that all retries are used and to wait . intead of crashing
        debugPrint('[AiService] insight error body: ${response.body}');
        if (response.statusCode == 429) {
          return "The AI is receiving too many requests right now. Please wait a moment and tap refresh to try again.";
        }
        return null;
      } catch (e) {    //handle actual crash
        debugPrint('[AiService] getInsight exception (attempt $attempt): $e');
        if (attempt >= maxRetries) return null;
        await Future.delayed(Duration(seconds: _backoffSeconds(attempt)));
      }
    }
    return null;
  }
//avoid hammerring a busy server and never wait less than 2 seconds
  static int _backoffSeconds(int attempt) {
    return (2 * (1 << (attempt - 1))).clamp(2, 30);
  }
// same idea for chat but sends converstation history 
  static Future<String?> chat({
    required String systemPrompt,
    required List<Map<String, String>> history,
  }) async {
    const maxRetries = 3;
    int attempt = 0;

    while (attempt < maxRetries) {
      attempt++;
      try {
        final response = await http
            .post(
              Uri.parse('$kApiBaseUrl/chat'),
              headers: {'Content-Type': 'application/json'},
              //instead of just a promp , send the full convo history
              body: jsonEncode({
                'system_prompt': systemPrompt,
                'history': history,
              }),
            )
            .timeout(
              const Duration(seconds: 30),
              onTimeout: () => http.Response('{"reply": null}', 408),
            );

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          return data['reply'] as String?;
        }

        if (response.statusCode == 429 && attempt < maxRetries) {
          final waitSeconds = _backoffSeconds(attempt);
          debugPrint('[AiService] chat 429 — waiting ${waitSeconds}s');
          await Future.delayed(Duration(seconds: waitSeconds));
          continue;
        }

        if (response.statusCode == 429) {
          return "The AI is busy right now. Please wait a moment and try again.";
        }
      } catch (e) {
        debugPrint('AiService.chat error (attempt $attempt): $e');
        if (attempt >= maxRetries) return null;
        await Future.delayed(Duration(seconds: _backoffSeconds(attempt)));
      }
    }
    return null;
  }

  //build the prompts for home screen
  static String buildHomeInsightPrompt(WellnessEntry w, AppState s) {
    return '''
Mood: ${w.mood.isNotEmpty ? w.mood : 'not logged'}, Sleep: ${w.sleepH}h${w.sleepM}m, Stress: ${(w.stress * 10).round()}/10, Energy: ${(w.energy * 10).round()}/10, Habits: ${s.completedHabitsCount}/${s.habits.length}, Balance: \$${s.balance.toStringAsFixed(0)}${s.cycleEnabled ? ', Cycle: ${s.currentPhase} day ${s.currentCycleDay}' : ''}
Give exactly 2 warm sentences referencing specific numbers. No greeting or sign-off.
''';
  }

  //build the prompt for the insights screen overall performance soo far
  static String buildInsightsSummaryPrompt(AppState s, List<DateTime> periodDates) {
    final entries = periodDates
        .map((d) => s.wellnessForDate(d))
        .where((e) => e != null)
        .cast<WellnessEntry>()
        .toList();

    String wellnessSummary;
    if (entries.isEmpty) {
      wellnessSummary = 'No wellness data logged for this period.';
    } else {
      final avgSleep  = entries.map((e) => e.sleepH + e.sleepM / 60.0).reduce((a, b) => a + b) / entries.length;
      final avgStress = entries.map((e) => e.stress * 10).reduce((a, b) => a + b) / entries.length;
      final avgEnergy = entries.map((e) => e.energy * 10).reduce((a, b) => a + b) / entries.length;
      final moods     = entries.map((e) => e.mood).where((m) => m.isNotEmpty).toList();
      final happyCount   = moods.where((m) => m == 'Happy').length;
      final neutralCount = moods.where((m) => m == 'Neutral').length;
      final lowCount     = moods.where((m) => m == 'Low').length;
      final moodStr = moods.isEmpty
          ? 'not logged'
          : '$happyCount happy, $neutralCount neutral, $lowCount low';
      wellnessSummary =
          'Avg sleep: ${avgSleep.toStringAsFixed(1)}h, avg stress: ${avgStress.toStringAsFixed(1)}/10, avg energy: ${avgEnergy.toStringAsFixed(1)}/10, moods: $moodStr across ${entries.length} logged days';
    }

    final balance = s.balance;
    final txCount = s.transactions.where((t) => periodDates.any((d) =>
        t.date.year == d.year &&
        t.date.month == d.month &&
        t.date.day == d.day)).length;
    final habitsInfo =
        '${s.completedHabitsCount}/${s.habits.length} habits completed today, ${(s.habitCompletionRate * 100).round()}% rate';
    final cycleInfo = s.cycleEnabled
        ? ', cycle phase: ${s.currentPhase} day ${s.currentCycleDay}'
        : '';

    return '''
Period summary — $wellnessSummary. Finance: \$${balance.toStringAsFixed(0)} balance, $txCount transactions this period. Habits: $habitsInfo$cycleInfo.
Give 3 sentences summarizing overall progress with one actionable tip. Be warm and specific. No bullet points, no greeting, no sign-off.
''';
  }
//prompt for chat 
  static String buildChatSystemPrompt(AppState s) {
    final w = s.todayWellness;
    final cycleSection = s.cycleEnabled
        ? '- Cycle day: ${s.currentCycleDay}, phase: ${s.currentPhase}\n- Cycle symptoms: ${s.cycleSymptoms.isNotEmpty ? s.cycleSymptoms.join(', ') : 'none'}'
        : '';

    return '''
You are Thrive AI, a friendly wellness coach inside the Thrive mobile app. Keep responses under 3 sentences unless asked for detail. Be warm and personal.

User data today:
- Mood: ${w.mood.isNotEmpty ? w.mood : 'not logged'}
- Sleep: ${w.sleepH}h ${w.sleepM}m
- Stress: ${(w.stress * 10).round()}/10
- Energy: ${(w.energy * 10).round()}/10
- Workout: ${(w.workout * 10).round()}/10
- Habits done: ${s.completedHabitsCount}/${s.habits.length}
- Balance: \$${s.balance.toStringAsFixed(2)}
$cycleSection
'''; // tell the ai who it is and feed it all of today's user data to give personalized responses 
  }
}


// APP ROOT

class ThriveApp extends StatelessWidget {
  const ThriveApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      //set global theme for the whole app
      theme: ThemeData(
        colorScheme: const ColorScheme.light(
            primary: kDarkGreen, secondary: kDarkGreen),
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
      ),
     //go to authrouter
      home: const AuthRouter(),
    );
  }
}

// AUTH ROUTER
// This is the single source of truth for navigation.
// When Firebase auth state changes (sign out / delete),
// it automatically routes to WelcomePage. No manual
// Navigator calls needed in ProfilePage.

class AuthRouter extends StatelessWidget {
  const AuthRouter({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(), //firebase stream that fires whenever the login state changes
      builder: (context, snapshot) { //show a loading spinner instead of blank page while firebase is checking id the user is logged in
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
              body: Center(child: CircularProgressIndicator()));
        }
        if (snapshot.hasData) return const MainScreen();
        return const WelcomePage();
      }, // if user logged in go to app
    );
  }
}

// WELCOME PAGE
class WelcomePage extends StatefulWidget { //stateful because it has animation and isnt static
  const WelcomePage({super.key});

  @override
  State<WelcomePage> createState() => _WelcomePageState();
}
//animate the welcome page with a fade
class _WelcomePageState extends State<WelcomePage>
    with SingleTickerProviderStateMixin {
  late AnimationController _animController;
  late Animation<double> _fadeAnim;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1200));
    _fadeAnim =
        CurvedAnimation(parent: _animController, curve: Curves.easeIn);
    _animController.forward();
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  @override
  //set backgrond to white and show logo image 
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: FadeTransition(
          opacity: _fadeAnim,
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Image.asset('assets/images/loginpage.png', height: 150),
                const SizedBox(height: 40),
                const Text('THRIVE',
                    style: TextStyle(fontSize: 48, fontFamily: 'MainFont')),
                const Text( //subline
                  'where everything connects ',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 32,
                      fontFamily: 'BeautifulDelicious',
                      color: Colors.black54),
                ),
                const SizedBox(height: 50),
                SizedBox(
                  width: 260,
                  child: ElevatedButton(
                    onPressed: () => Navigator.push(context, //when  get started is pushed we go to login screen
                        MaterialPageRoute(builder: (_) => const LoginScreen())),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: kCardGreen,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                      elevation: 0,
                    ),
                    child: const Text('Get Started',
                        style: TextStyle(color: Colors.black)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// LOGIN SCREEN
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailCtrl    = TextEditingController(); //read what user writes
  final _passwordCtrl = TextEditingController();
  bool _passwordHidden = true; //password visible/invisible
  bool _isLoading      = false;
// Show a temporary snackbar message at the bottom of the screen
  void _showMessage(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(text)));
  }
//dont allow user to go back to login screen after logging in
  void _navigateToMain() {
    Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const MainScreen()),
        (r) => false);
  }
//remove any accidental spaces , if fields are empty show an error
  Future<void> _login() async {
    final email = _emailCtrl.text.trim();
    final pass  = _passwordCtrl.text.trim();
    if (email.isEmpty || pass.isEmpty) {
      _showMessage('Please fill in all fields.');
      return;
    }
    setState(() => _isLoading = true);
    try {
      await FirebaseAuth.instance //send credentials to firebase
          .signInWithEmailAndPassword(email: email, password: pass);
      _showMessage('Welcome back!');
      _navigateToMain();
      //catch firebase errors and show messages
    } on FirebaseAuthException catch (e) {
      if (e.code == 'wrong-password' || e.code == 'user-not-found') {
        _showMessage('Invalid email or password.');
      } else {
        _showMessage(e.message ?? 'Login failed.');
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _signup() async {
    final email = _emailCtrl.text.trim();
    final pass  = _passwordCtrl.text.trim();
    if (email.isEmpty || pass.isEmpty) {
      _showMessage('Please fill in all fields.');
      return;
    }
    setState(() => _isLoading = true);
    try { //create new acc instead of signing into an existing one
      await FirebaseAuth.instance
          .createUserWithEmailAndPassword(email: email, password: pass);
      _showMessage('Account created! Welcome to Thrive.');
      _navigateToMain();
    } on FirebaseAuthException catch (e) {
      _showMessage(e.message ?? 'Signup failed.');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }
//reset password (firebase handles this) just send feedback
  Future<void> _resetPassword() async {
    final email = _emailCtrl.text.trim();
    if (email.isEmpty) { _showMessage('Enter your email first.'); return; }
    await FirebaseAuth.instance.sendPasswordResetEmail(email: email);
    _showMessage('Password reset link sent.');
  }

//open google s sign in popup , get google account
// if user cancelled stop
  Future<void> _googleLogin() async {
    setState(() => _isLoading = true);
    try {
      final googleUser = await GoogleSignIn().signIn();
      if (googleUser == null) return;
      final googleAuth = await googleUser.authentication;
      final credential = GoogleAuthProvider.credential(
        //get security tokens from google and give them to firebase to complete the login
          accessToken: googleAuth.accessToken, idToken: googleAuth.idToken);
      await FirebaseAuth.instance.signInWithCredential(credential);
      _navigateToMain();
    } catch (_) {
      _showMessage('Google sign-in failed.');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  InputDecoration _fieldDecoration(String hint, IconData icon,
      {Widget? suffix}) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: Colors.black38),
      prefixIcon: Icon(icon, color: Colors.black45, size: 20),
      suffixIcon: suffix,
      filled: true,
      fillColor: Colors.white,
      contentPadding:
          const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: kDarkGreen, width: 1.5)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const SizedBox(height: 48),
              Image.asset('assets/images/loginpage.png', height: 72),
              const Text('THRIVE',
                  style: TextStyle(fontSize: 32, fontFamily: 'MainFont')),
              const SizedBox(height: 28),
              const Text('Welcome', style: TextStyle(fontSize: 28)),
              const SizedBox(height: 4),
              const Text('Sign in to continue',
                  style: TextStyle(fontSize: 18, color: Colors.black54)),
              const SizedBox(height: 28),
              _ShadowCard(
                child: TextField(
                  controller: _emailCtrl,
                  keyboardType: TextInputType.emailAddress,
                  decoration: _fieldDecoration('Email', Icons.mail_outline),
                ),
              ),
              const SizedBox(height: 14),
              _ShadowCard(
                child: TextField(
                  controller: _passwordCtrl,
                  obscureText: _passwordHidden,
                  decoration: _fieldDecoration('Password', Icons.key_outlined,
                      suffix: IconButton(
                        icon: Icon(
                            _passwordHidden
                                ? Icons.visibility_off
                                : Icons.visibility,
                            color: Colors.black38,
                            size: 20),
                        onPressed: () =>
                            setState(() => _passwordHidden = !_passwordHidden),
                      )),
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: 200,
                height: 48,
                child: ElevatedButton(
                  onPressed: _isLoading ? null : _login,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: kCardGreen,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                    elevation: 0,
                  ),
                  child: _isLoading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.black54))
                      : const Text('Login',
                          style:
                              TextStyle(color: Colors.black, fontSize: 16)),
                ),
              ),
              const SizedBox(height: 2),
              TextButton(
                onPressed: _isLoading ? null : _signup,
                child: const Text("Don't have an account? Create one",
                    style: TextStyle(color: kDarkGreen, fontSize: 13)),
              ),
              TextButton(
                onPressed: _isLoading ? null : _resetPassword,
                child: const Text('Forgot password?',
                    style: TextStyle(color: Colors.black54, fontSize: 13)),
              ),
              const SizedBox(height: 8),
              const Text('Or login with',
                  style: TextStyle(color: Colors.black54, fontSize: 14)),
              const SizedBox(height: 14),
              _SocialIconButton(
                onTap: _googleLogin,
                child: Image.asset('assets/images/google.png', width: 28),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}

class _ShadowCard extends StatelessWidget {
  final Widget child;
  const _ShadowCard({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              blurRadius: 12,
              offset: const Offset(0, 4))
        ],
      ),
      child: child,
    );
  }
}

class _SocialIconButton extends StatelessWidget {
  final VoidCallback onTap;
  final Widget child;
  const _SocialIconButton({required this.onTap, required this.child});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 60,
        height: 60,
        decoration: BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.10),
                blurRadius: 10,
                offset: const Offset(0, 3))
          ],
        ),
        child: Center(child: child),
      ),
    );
  }
}

// APP STATE (handle habits wellness tracking transactions cycle tracking notifictions pfp local data)
class AppState extends ChangeNotifier { //allow widgets to change when data updates
  bool cycleEnabled         = false; //is period tracking enabled
  int  menstrualDays        = 5; //default
  int  cycleDays            = 28;//defauly
  DateTime? lastPeriodStart;
  final List<String> cycleSymptoms     = []; //store symptoms
  bool notificationsEnabled = false; 
  String? localProfilePhotoPath;

  final Map<String, WellnessEntry> wellnessData  = {}; //store wellness entries by date
  final List<HabitModel>           habits        = []; //store habits
  final List<TransactionModel>     transactions  = []; //store transactions

  Future<void> loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance(); //load data from sharedprefrences

    cycleEnabled         = prefs.getBool(kPrefCycleEnabled)  ?? false;
    menstrualDays        = prefs.getInt(kPrefMenstrualD)     ?? 5;
    cycleDays            = prefs.getInt(kPrefCycleDays)      ?? 28;
    notificationsEnabled = prefs.getBool(kPrefNotifications) ?? false;
    localProfilePhotoPath = prefs.getString(kPrefProfilePhoto);

    final lastPeriodStr = prefs.getString(kPrefLastPeriod);
    if (lastPeriodStr != null) {
      lastPeriodStart = DateTime.tryParse(lastPeriodStr);
    }

    final habitsJson = prefs.getString(kPrefHabits);
    if (habitsJson != null) {
      final List decoded = jsonDecode(habitsJson);
      habits.addAll(decoded.map((h) => HabitModel(
            name: h['name'],
            goal: h['goal'],
            done: h['done'] ?? false,
            reminder: h['reminder'] ?? false,
          )));
    }

    final txJson = prefs.getString(kPrefTransactions);
    if (txJson != null) {
      final List decoded = jsonDecode(txJson);
      transactions.addAll(decoded.map((t) => TransactionModel(
            name:   t['name'],
            amount: (t['amount'] as num).toDouble(),
            date:   DateTime.parse(t['date']),
          )));
    }

    final wellnessJson = prefs.getString(kPrefWellness);
    if (wellnessJson != null) {
      final Map decoded = jsonDecode(wellnessJson);
      decoded.forEach((key, val) {
        wellnessData[key] = WellnessEntry(
          mood:    val['mood'] ?? '',
          sleepH:  val['sleepH'] ?? 0,
          sleepM:  val['sleepM'] ?? 0,
          stress:  (val['stress'] ?? 0.5).toDouble(),
          workout: (val['workout'] ?? 0.5).toDouble(),
          energy:  (val['energy'] ?? 0.5).toDouble(),
        );
      });
    }

    notifyListeners(); //rebuild widgets using the new state
  }

  Future<void> clearAllData() async { //delete saved data from phone stporage and reset all settings
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    habits.clear();
    transactions.clear();
    wellnessData.clear();
    cycleSymptoms.clear();
    cycleEnabled         = false;
    menstrualDays        = 5;
    cycleDays            = 28;
    lastPeriodStart      = null;
    notificationsEnabled = false;
    localProfilePhotoPath = null;
    notifyListeners();
  }

  Future<void> _saveHabits() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(habits.map((h) => {
          'name':     h.name,
          'goal':     h.goal,
          'done':     h.done,
          'reminder': h.reminder,
        }).toList());
    await prefs.setString(kPrefHabits, encoded);
  }

  Future<void> _saveTransactions() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(transactions.map((t) => {
          'name':   t.name,
          'amount': t.amount,
          'date':   t.date.toIso8601String(),
        }).toList());
    await prefs.setString(kPrefTransactions, encoded);
  }

  Future<void> _saveWellness() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(wellnessData.map((k, v) => MapEntry(k, {
          'mood':    v.mood,
          'sleepH':  v.sleepH,
          'sleepM':  v.sleepM,
          'stress':  v.stress,
          'workout': v.workout,
          'energy':  v.energy,
        })));
    await prefs.setString(kPrefWellness, encoded);
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kPrefCycleEnabled, cycleEnabled);
    await prefs.setInt(kPrefMenstrualD,    menstrualDays);
    await prefs.setInt(kPrefCycleDays,     cycleDays);
    await prefs.setBool(kPrefNotifications, notificationsEnabled);
    if (lastPeriodStart != null) {
      await prefs.setString(kPrefLastPeriod, lastPeriodStart!.toIso8601String());
    }
  }

  Future<void> setLocalProfilePhoto(String path) async {
    localProfilePhotoPath = path.isEmpty ? null : path;
    final prefs = await SharedPreferences.getInstance();
    if (path.isEmpty) {
      await prefs.remove(kPrefProfilePhoto);
    } else {
      await prefs.setString(kPrefProfilePhoto, path);
    }
    notifyListeners();
  }
//return today s wellness entry
  WellnessEntry get todayWellness {
    final key = _dateKey(DateTime.now());
    return wellnessData[key] ?? WellnessEntry();
  }

  bool get hasTodayWellness {
    final key = _dateKey(DateTime.now());
    final entry = wellnessData[key];
    return entry != null && entry.mood.isNotEmpty;
  }

  WellnessEntry? wellnessForDate(DateTime date) {
    return wellnessData[_dateKey(date)];
  }
//count completed habits
  int    get completedHabitsCount => habits.where((h) => h.done).length;
  double get habitCompletionRate  => habits.isEmpty ? 0 : completedHabitsCount / habits.length;
  double get balance              => transactions.fold(0.0, (s, t) => s + t.amount);

  int get currentCycleDay {
    if (lastPeriodStart == null) return 0;
    final rawDay = DateTime.now().difference(lastPeriodStart!).inDays + 1;
    if (rawDay <= 0) return 1;
    final dayInCycle = ((rawDay - 1) % cycleDays) + 1;
    return dayInCycle;
  }

  int get _rawCycleDay {
    if (lastPeriodStart == null) return 0;
    return DateTime.now().difference(lastPeriodStart!).inDays + 1;
  }

  String get currentPhase {
    final day = currentCycleDay;
    if (day == 0)             return 'Not set';
    if (day <= menstrualDays) return 'Menstrual';
    if (day <= 13)            return 'Follicular';
    if (day <= 16)            return 'Ovulation';
    if (day <= cycleDays)     return 'Luteal';
    return 'Next cycle due';
  }

  String get phaseTip {
    switch (currentPhase) {
      case 'Menstrual':  return 'Rest and gentle movement are best.\nStay hydrated and be kind to yourself.';
      case 'Follicular': return 'Energy is rising great time to start new projects.\nTry strength training and social activities.';
      case 'Ovulation':  return 'Your energy is highest during this phase.\nIntense exercise and focused work are recommended.';
      case 'Luteal':     return 'Focus on calming activities and self-care.\nLight exercise and journaling can help.';
      default:           return 'Log your last period to get personalized tips.';
    }
  }

  void saveWellness(WellnessEntry entry) {
    wellnessData[_dateKey(DateTime.now())] = entry;
    _saveWellness();
    notifyListeners();
  }

  void addHabit(HabitModel h)    { habits.add(h);                   _saveHabits(); notifyListeners(); }
  void toggleHabit(int i)        { habits[i].done = !habits[i].done; _saveHabits(); notifyListeners(); }
  void deleteHabit(int i)        { habits.removeAt(i);               _saveHabits(); notifyListeners(); }

  void addTransaction(TransactionModel t) {
    transactions.insert(0, t);
    _saveTransactions();
    notifyListeners();
  }

  void setCycleEnabled(bool v)         { cycleEnabled = v;                 _saveSettings(); notifyListeners(); }
  void setNotificationsEnabled(bool v) { notificationsEnabled = v;         _saveSettings(); notifyListeners(); }
  void setCycleDays(int m, int c)      { menstrualDays = m; cycleDays = c; _saveSettings(); notifyListeners(); }
  void setLastPeriodStart(DateTime d)  { lastPeriodStart = d;              _saveSettings(); notifyListeners(); }
  void addCycleSymptom(String s)       { cycleSymptoms.add(s);             notifyListeners(); }

  String _dateKey(DateTime d) => '${d.year}-${d.month}-${d.day}';

  DateTime? get nextPeriodDate {
    if (lastPeriodStart == null) return null;
    final raw = _rawCycleDay;
    final completedCycles = ((raw - 1) ~/ cycleDays);
    return lastPeriodStart!.add(Duration(days: (completedCycles + 1) * cycleDays));
  }
}

// DATA MODELS
class WellnessEntry {
  String mood;
  int    sleepH;
  int    sleepM;
  double stress;
  double workout;
  double energy;

  WellnessEntry({
    this.mood    = '',
    this.sleepH  = 0,
    this.sleepM  = 0,
    this.stress  = 0.5,
    this.workout = 0.5,
    this.energy  = 0.5,
  });
}

class HabitModel {
  String name;
  String goal;
  bool   done;
  bool   reminder;
  HabitModel({
    required this.name,
    required this.goal,
    this.done     = false,
    this.reminder = false,
  });
}

class TransactionModel {
  String   name;
  double   amount;
  DateTime date;
  TransactionModel({required this.name, required this.amount, required this.date});

  String get dateLabel {
    final now = DateTime.now();
    if (date.year == now.year && date.month == now.month && date.day == now.day) {
      return 'Today';
    }
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${months[date.month - 1]} ${date.day}';
  }
}


//bottom navigation 
class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _selectedTab = 0;
  final AppState _appState = AppState();

  @override
  void initState() {
    super.initState();
    _appState.loadFromPrefs();
  }

  void _onTabTap(int i) => setState(() => _selectedTab = i);

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _appState,
      builder: (context, _) {
        final showCycle = _appState.cycleEnabled;

        final List<Widget> pages = [
          HomePage(appState: _appState, onNavigate: _onTabTap),
          HabitsPage(appState: _appState),
          InsightsPage(appState: _appState),
          if (showCycle) CyclePage(appState: _appState),
          ProfilePage(appState: _appState),
        ];

        final navItems = <BottomNavigationBarItem>[
          const BottomNavigationBarItem(icon: Icon(Icons.home_outlined),         activeIcon: Icon(Icons.home),        label: 'Home'),
          const BottomNavigationBarItem(icon: Icon(Icons.edit_note_outlined),    activeIcon: Icon(Icons.edit_note),   label: 'Habits'),
          const BottomNavigationBarItem(icon: Icon(Icons.bar_chart_outlined),    activeIcon: Icon(Icons.bar_chart),   label: 'Insights'),
          if (showCycle)
            const BottomNavigationBarItem(icon: Icon(Icons.water_drop_outlined), activeIcon: Icon(Icons.water_drop),  label: 'Cycle'),
          const BottomNavigationBarItem(icon: Icon(Icons.person_outline),        activeIcon: Icon(Icons.person),      label: 'Profile'),
        ];

        final maxIndex = pages.length - 1;
        if (_selectedTab > maxIndex) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => _selectedTab = 0);
          });
        }
        final safeIndex = _selectedTab.clamp(0, maxIndex);

        return Scaffold(
          body: pages[safeIndex],
          bottomNavigationBar: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(20), topRight: Radius.circular(20)),
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withValues(alpha: 0.08),
                    blurRadius: 12,
                    offset: const Offset(0, -2))
              ],
            ),
            child: ClipRRect(
              borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(20), topRight: Radius.circular(20)),
              child: BottomNavigationBar(
                currentIndex:         safeIndex,
                onTap:                _onTabTap,
                type:                 BottomNavigationBarType.fixed,
                backgroundColor:      Colors.white,
                selectedItemColor:    kDarkGreen,
                unselectedItemColor:  Colors.black45,
                showUnselectedLabels: true,
                items:                navItems,
              ),
            ),
          ),
        );
      },
    );
  }
}

// HOME PAGE
class HomePage extends StatefulWidget {
  final AppState appState;
  final void Function(int) onNavigate;
  const HomePage({super.key, required this.appState, required this.onNavigate});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String? _aiInsightText;
  bool    _aiInsightLoading = false;
  bool    _autoFetchDone = false;

  @override
  void initState() {
    super.initState();
    widget.appState.addListener(_checkAndAutoFetch);
  }

  @override
  void dispose() {
    widget.appState.removeListener(_checkAndAutoFetch);
    super.dispose();
  }

  void _checkAndAutoFetch() {
    if (!_autoFetchDone &&
        widget.appState.hasTodayWellness &&
        !_aiInsightLoading &&
        _aiInsightText == null) {
      _autoFetchDone = true;
      _fetchInsight();
    }
  }

  Future<void> _fetchInsight() async {
    setState(() {
      _aiInsightLoading = true;
      _aiInsightText    = null;
    });

    final w      = widget.appState.todayWellness;
    final prompt = AiService.buildHomeInsightPrompt(w, widget.appState);
    final result = await AiService.getInsight(prompt);

    if (mounted) {
      setState(() {
        _aiInsightText    = result;
        _aiInsightLoading = false;
      });
    }
  }

  double _computeReadinessFallback(WellnessEntry w) {
    final totalSleepH = w.sleepH + w.sleepM / 60.0;
    final sleepScore = (totalSleepH >= 7 && totalSleepH <= 9)
        ? 1.0
        : (totalSleepH < 7
                ? totalSleepH / 7.0
                : 1.0 - (totalSleepH - 9) / 6.0)
            .clamp(0.0, 1.0);
    final stressScore = 1.0 - w.stress;
    final energyScore = w.energy;
    return ((sleepScore * 0.4) + (stressScore * 0.3) + (energyScore * 0.3))
        .clamp(0.0, 1.0);
  }

  String _levelLabel(double v) {
    if (v < 0.35) return 'Low';
    if (v < 0.65) return 'Medium';
    return 'High';
  }

  String _getFirstName(User? user) {
    if (user == null) return 'there';
    if (user.displayName != null && user.displayName!.trim().isNotEmpty) {
      return user.displayName!.trim().split(' ').first;
    }
    if (user.email != null && user.email!.isNotEmpty) {
      return user.email!.split('@').first;
    }
    return 'there';
  }

  @override
  Widget build(BuildContext context) {
    final user      = FirebaseAuth.instance.currentUser;
    final firstName = _getFirstName(user);

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: AnimatedBuilder(
          animation: widget.appState,
          builder: (context, _) {
            _checkAndAutoFetch();

            final w         = widget.appState.todayWellness;
            final hasData   = w.mood.isNotEmpty;
            final readiness = hasData ? _computeReadinessFallback(w) : 0.0;

            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Flexible(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Hello, $firstName 👋',
                                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w500, color: Colors.black87),
                                overflow: TextOverflow.ellipsis),
                            const Text('How are you feeling today?',
                                style: TextStyle(fontSize: 13, color: Colors.black45)),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: () {
                          final profileIndex = widget.appState.cycleEnabled ? 4 : 3;
                          widget.onNavigate(profileIndex);
                        },
                        child: _ProfileAvatar(
                          user: user,
                          localPhotoPath: widget.appState.localProfilePhotoPath,
                          radius: 21,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  _HomeCard(
                    child: Column(
                      children: [
                        const SizedBox(height: 6),
                        SizedBox(
                          width: 110, height: 110,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              SizedBox(
                                width: 110, height: 110,
                                child: CircularProgressIndicator(
                                  value: readiness,
                                  strokeWidth: 10,
                                  backgroundColor: kLightGreen.withValues(alpha: 0.4),
                                  valueColor: const AlwaysStoppedAnimation<Color>(kMedGreen),
                                ),
                              ),
                              Text(hasData ? '${(readiness * 100).round()}%' : '—',
                                  style: const TextStyle(fontSize: 26)),
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),
                        const Text('Ready Today', style: TextStyle(fontSize: 20)),
                        const SizedBox(height: 4),
                        const Text('Based on sleep, stress, energy & activity',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.black54, fontSize: 13)),
                        const SizedBox(height: 6),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      _StatChip(icon: Icons.nightlight_round,       label: 'Sleep',  value: hasData ? '${w.sleepH}h ${w.sleepM}m' : '—'),
                      const SizedBox(width: 8),
                      _StatChip(icon: Icons.sentiment_satisfied_alt, label: 'Mood',   value: hasData ? w.mood : '—'),
                      const SizedBox(width: 8),
                      _StatChip(icon: Icons.self_improvement,        label: 'Stress', value: hasData ? _levelLabel(w.stress) : '—'),
                      const SizedBox(width: 8),
                      _StatChip(icon: Icons.bolt,                    label: 'Energy', value: hasData ? _levelLabel(w.energy) : '—'),
                    ],
                  ),
                  const SizedBox(height: 14),
                  _HomeCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text("Today's Insight", style: TextStyle(fontSize: 18)),
                            if (hasData)
                              GestureDetector(
                                  onTap: _fetchInsight,
                                  child: const Icon(Icons.refresh, size: 18, color: kMedGreen)),
                          ],
                        ),
                        const SizedBox(height: 6),
                        if (!hasData)
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Log your wellness to unlock your daily AI insight.',
                                style: TextStyle(fontSize: 14, color: Colors.black54, height: 1.5),
                              ),
                              const SizedBox(height: 10),
                              GestureDetector(
                                onTap: () => Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                        builder: (_) => WellnessPage(appState: widget.appState))),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                  decoration: BoxDecoration(
                                    color: kDarkGreen,
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: const Text('Log Wellness Now',
                                      style: TextStyle(color: Colors.white, fontSize: 13)),
                                ),
                              ),
                            ],
                          )
                        else if (_aiInsightLoading)
                          const Row(children: [
                            SizedBox(width: 16, height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2, color: kMedGreen)),
                            SizedBox(width: 8),
                            Text('Generating insight…',
                                style: TextStyle(color: Colors.black54, fontSize: 13)),
                          ])
                        else
                          Text(
                            _aiInsightText ?? 'Tap the refresh button to generate an AI insight.',
                            style: const TextStyle(fontSize: 14, color: Colors.black87, height: 1.5),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(child: _NavActionButton(icon: Icons.edit_note,   label: 'Habits',   onTap: () => widget.onNavigate(1))),
                      const SizedBox(width: 12),
                      Expanded(child: _NavActionButton(
                          icon: Icons.spa_outlined, label: 'Wellness',
                          onTap: () => Navigator.push(context,
                              MaterialPageRoute(builder: (_) => WellnessPage(appState: widget.appState))))),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(child: _NavActionButton(
                          icon: Icons.account_balance_wallet_outlined, label: 'Finance',
                          onTap: () => Navigator.push(context,
                              MaterialPageRoute(builder: (_) => FinancePage(appState: widget.appState))))),
                      const SizedBox(width: 12),
                      Expanded(child: _NavActionButton(
                          icon: Icons.chat_bubble_outline, label: 'AI Chat',
                          onTap: () => Navigator.push(context,
                              MaterialPageRoute(builder: (_) => AiChatPage(appState: widget.appState))))),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

// Profile pic
class _ProfileAvatar extends StatelessWidget {
  final User?   user;
  final String? localPhotoPath;
  final double  radius;
  const _ProfileAvatar({required this.user, required this.localPhotoPath, required this.radius});

  String _initials() {
    if (user == null) return '?';
    if (user!.displayName != null && user!.displayName!.trim().isNotEmpty) {
      final parts = user!.displayName!.trim().split(' ');
      if (parts.length >= 2) return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
      return parts[0][0].toUpperCase();
    }
    if (user!.email != null && user!.email!.isNotEmpty) {
      return user!.email![0].toUpperCase();
    }
    return '?';
  }

  @override
  Widget build(BuildContext context) {
    if (localPhotoPath != null && localPhotoPath!.isNotEmpty) {
      final file = File(localPhotoPath!);
      if (file.existsSync()) {
        return CircleAvatar(radius: radius, backgroundImage: FileImage(file));
      }
    }
    if (user?.photoURL != null) {
      return CircleAvatar(radius: radius, backgroundImage: NetworkImage(user!.photoURL!));
    }
    return CircleAvatar(
      radius: radius,
      backgroundColor: kCardGreen,
      child: Text(_initials(),
          style: TextStyle(fontSize: radius * 0.7, fontWeight: FontWeight.bold, color: kDarkGreen)),
    );
  }
}

class _HomeCard extends StatelessWidget {
  final Widget child;
  const _HomeCard({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.07), blurRadius: 14, offset: const Offset(0, 4))
        ],
      ),
      child: child,
    );
  }
}

class _StatChip extends StatelessWidget {
  final IconData icon;
  final String   label;
  final String   value;
  const _StatChip({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        decoration: BoxDecoration(
          color: kCardGreen,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(color: Colors.black.withValues(alpha: 0.07), blurRadius: 6, offset: const Offset(0, 2))
          ],
        ),
        child: Column(
          children: [
            Icon(icon, size: 22),
            const SizedBox(height: 4),
            Text(label, style: const TextStyle(fontSize: 11)),
            Text(value,
                style: const TextStyle(fontSize: 11, color: kDarkGreen, fontWeight: FontWeight.w600),
                overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
    );
  }
}

class _NavActionButton extends StatelessWidget {
  final IconData     icon;
  final String       label;
  final VoidCallback onTap;
  const _NavActionButton({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 66,
        decoration: BoxDecoration(
          color: kDarkGreen,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(color: kDarkGreen.withValues(alpha: 0.3), blurRadius: 8, offset: const Offset(0, 3))
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: Colors.white, size: 22),
            const SizedBox(width: 8),
            Text(label, style: const TextStyle(color: Colors.white, fontSize: 17)),
          ],
        ),
      ),
    );
  }
}

// HABITS PAGE
class HabitsPage extends StatefulWidget {
  final AppState appState;
  const HabitsPage({super.key, required this.appState});

  @override
  State<HabitsPage> createState() => _HabitsPageState();
}

class _HabitsPageState extends State<HabitsPage> {
  void _showAddHabitDialog() {
    final nameCtrl = TextEditingController();
    final goalCtrl = TextEditingController();
    bool reminder  = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Center(child: Text('Habit', style: TextStyle(fontSize: 24))),
                const SizedBox(height: 20),
                const Text('Habit Name'),
                const SizedBox(height: 8),
                _FormTextField(controller: nameCtrl, hint: 'Name'),
                const SizedBox(height: 14),
                const Text('Goal'),
                const SizedBox(height: 8),
                _FormTextField(controller: goalCtrl, hint: 'Goal (e.g. 30 min daily)'),
                const SizedBox(height: 14),
                const Text('Reminder'),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Icon(Icons.notifications_outlined, size: 20),
                    const SizedBox(width: 8),
                    const Expanded(child: Text('Set a daily reminder')),
                    GestureDetector(
                      onTap: () => setS(() => reminder = !reminder),
                      child: Container(
                        width: 32, height: 32,
                        decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: kDarkGreen, width: 1.5)),
                        child: reminder ? const Icon(Icons.check, size: 18, color: kDarkGreen) : null,
                      ),
                    ),
                  ],
                ),
                const Divider(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(ctx),
                        style: OutlinedButton.styleFrom(
                            side: BorderSide(color: Colors.grey[300]!),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                            backgroundColor: Colors.grey[100]),
                        child: const Text('Cancel', style: TextStyle(color: Colors.black54)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () {
                          if (nameCtrl.text.trim().isNotEmpty) {
                            widget.appState.addHabit(HabitModel(
                              name:     nameCtrl.text.trim(),
                              goal:     goalCtrl.text.trim(),
                              reminder: reminder,
                            ));
                          }
                          Navigator.pop(ctx);
                        },
                        style: ElevatedButton.styleFrom(
                            backgroundColor: kMedGreen,
                            elevation: 0,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                        child: const Text('Save', style: TextStyle(color: Colors.white)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: AnimatedBuilder(
          animation: widget.appState,
          builder: (context, _) {
            final habits    = widget.appState.habits;
            final pct       = widget.appState.habitCompletionRate;
            final completed = widget.appState.completedHabitsCount;

            return Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Habits', style: TextStyle(fontSize: 32)),
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: kMedGreen.withValues(alpha: 0.4)),
                      boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 10)],
                    ),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 74, height: 74,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              SizedBox(
                                width: 74, height: 74,
                                child: CircularProgressIndicator(
                                  value: pct,
                                  strokeWidth: 8,
                                  backgroundColor: kLightGreen.withValues(alpha: 0.4),
                                  valueColor: const AlwaysStoppedAnimation<Color>(kMedGreen),
                                ),
                              ),
                              Text('${(pct * 100).round()}%', style: const TextStyle(fontSize: 16)),
                            ],
                          ),
                        ),
                        const SizedBox(width: 18),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text("Today's completion", style: TextStyle(fontSize: 17)),
                              const SizedBox(height: 4),
                              Text(
                                habits.isEmpty
                                    ? 'Add your first habit below!'
                                    : completed == habits.length
                                        ? 'Amazing! All habits done! 🎉'
                                        : 'Great Job! Keep building\nconsistent habits.',
                                style: const TextStyle(fontSize: 13, color: Colors.black54),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  const Text("Today's Habits", style: TextStyle(fontSize: 22)),
                  const SizedBox(height: 10),
                  Expanded(
                    child: habits.isEmpty
                        ? const Center(
                            child: Text('No habits yet.\nTap "Add New Habit" to get started!',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: Colors.black45, fontSize: 16)))
                        : ListView.separated(
                            itemCount: habits.length,
                            separatorBuilder: (context, index) => const SizedBox(height: 10),
                            itemBuilder: (ctx, i) {
                              final habit = habits[i];
                              return Container(
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(color: kMedGreen.withValues(alpha: 0.4)),
                                  boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 6)],
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(habit.name, style: const TextStyle(fontSize: 19)),
                                          if (habit.goal.isNotEmpty)
                                            Text(habit.goal, style: const TextStyle(fontSize: 13, color: Colors.black54)),
                                        ],
                                      ),
                                    ),
                                    PopupMenuButton<String>(
                                      icon: const Icon(Icons.more_vert, color: Colors.black45),
                                      onSelected: (val) {
                                        if (val == 'delete') widget.appState.deleteHabit(i);
                                      },
                                      itemBuilder: (_) => [
                                        const PopupMenuItem(value: 'delete', child: Text('Delete')),
                                      ],
                                    ),
                                    GestureDetector(
                                      onTap: () => widget.appState.toggleHabit(i),
                                      child: Container(
                                        width: 38, height: 38,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          border: Border.all(color: kDarkGreen, width: 1.5),
                                          color: habit.done ? kDarkGreen.withValues(alpha: 0.1) : Colors.transparent,
                                        ),
                                        child: habit.done
                                            ? const Icon(Icons.check, color: kDarkGreen, size: 20)
                                            : null,
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ElevatedButton.icon(
                      onPressed: _showAddHabitDialog,
                      icon: const Icon(Icons.add_circle, color: Colors.white, size: 20),
                      label: const Text('Add New Habit', style: TextStyle(color: Colors.white, fontSize: 17)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: kDarkGreen,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
                        elevation: 0,
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _FormTextField extends StatelessWidget {
  final TextEditingController controller;
  final String                hint;
  final TextInputType?        keyboardType;
  const _FormTextField({required this.controller, required this.hint, this.keyboardType});

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller:   controller,
      keyboardType: keyboardType,
      decoration: InputDecoration(
        hintText:  hint,
        hintStyle: const TextStyle(color: Colors.black38),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: kMedGreen)),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: kDarkGreen, width: 1.5)),
      ),
    );
  }
}

// WELLNESS PAGE
class WellnessPage extends StatefulWidget {
  final AppState appState;
  const WellnessPage({super.key, required this.appState});

  @override
  State<WellnessPage> createState() => _WellnessPageState();
}

class _WellnessPageState extends State<WellnessPage> {
  late String mood;
  late int    sleepH;
  late int    sleepM;
  late double stress;
  late double workout;
  late double energy;

  @override
  void initState() {
    super.initState();
    final existing = widget.appState.todayWellness;
    mood    = existing.mood;
    sleepH  = existing.sleepH;
    sleepM  = existing.sleepM;
    stress  = existing.stress;
    workout = existing.workout;
    energy  = existing.energy;
  }

  String _monthName(int m) {
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return months[m - 1];
  }

  @override
  Widget build(BuildContext context) {
    final now     = DateTime.now();
    final dateStr = 'Today, ${_monthName(now.month)} ${now.day}';

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Wellness', style: TextStyle(fontSize: 32)),
              const Text('Track your daily state',
                  style: TextStyle(fontSize: 16, color: Colors.black54)),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(color: kCardGreen, borderRadius: BorderRadius.circular(16)),
                child: Row(
                  children: [
                    const Icon(Icons.calendar_today_outlined, size: 22),
                    const SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(dateStr, style: const TextStyle(fontSize: 17)),
                        const Text('How are you feeling today?', style: TextStyle(fontSize: 13)),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              _WellnessCard(
                icon: Icons.sentiment_satisfied_alt_outlined,
                title: 'Mood',
                child: Row(
                  children: ['Happy', 'Neutral', 'Low'].map((m) {
                    final selected = mood == m;
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: GestureDetector(
                        onTap: () => setState(() => mood = m),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: selected ? kMedGreen : Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: selected ? kMedGreen : Colors.black26),
                          ),
                          child: Column(
                            children: [
                              Icon(
                                m == 'Happy' ? Icons.sentiment_very_satisfied
                                    : m == 'Neutral' ? Icons.sentiment_neutral
                                    : Icons.sentiment_dissatisfied,
                                color: selected ? Colors.white : Colors.black, size: 22,
                              ),
                              const SizedBox(height: 2),
                              Text(m, style: TextStyle(color: selected ? Colors.white : Colors.black, fontSize: 11)),
                            ],
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
              const SizedBox(height: 10),
              _WellnessCard(
                icon: Icons.nightlight_round,
                title: 'Sleep',
                subtitle: 'Hours slept',
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _NumberSpinner(value: sleepH, onUp: () => setState(() => sleepH = (sleepH + 1) % 24), onDown: () => setState(() => sleepH = (sleepH - 1 + 24) % 24), suffix: 'h'),
                    const SizedBox(width: 10),
                    _NumberSpinner(value: sleepM, onUp: () => setState(() => sleepM = (sleepM + 5) % 60), onDown: () => setState(() => sleepM = (sleepM - 5 + 60) % 60), suffix: 'm'),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              _WellnessSliderCard(icon: Icons.self_improvement, title: 'Stress Level',      subtitle: 'How stressed did you feel today?',  value: stress,  minLabel: 'Low',   midLabel: 'Medium',   maxLabel: 'High',    onChanged: (v) => setState(() => stress = v)),
              const SizedBox(height: 10),
              _WellnessSliderCard(icon: Icons.fitness_center,   title: 'Workout Intensity', subtitle: 'How intense was your workout?',     value: workout, minLabel: 'Light', midLabel: 'Moderate', maxLabel: 'Intense', onChanged: (v) => setState(() => workout = v)),
              const SizedBox(height: 10),
              _WellnessSliderCard(icon: Icons.bolt,             title: 'Energy Level',      subtitle: 'How energetic do you feel today?',  value: energy,  minLabel: 'Low',   midLabel: 'Medium',   maxLabel: 'High',    onChanged: (v) => setState(() => energy = v)),
              const SizedBox(height: 20),
              Center(
                child: SizedBox(
                  width: 160, height: 48,
                  child: ElevatedButton(
                    onPressed: () {
                      if (mood.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Please select your mood.')));
                        return;
                      }
                      widget.appState.saveWellness(WellnessEntry(
                        mood: mood, sleepH: sleepH, sleepM: sleepM,
                        stress: stress, workout: workout, energy: energy,
                      ));
                      ScaffoldMessenger.of(context)
                          .showSnackBar(const SnackBar(content: Text('Wellness saved!')));
                      Navigator.pop(context);
                    },
                    style: ElevatedButton.styleFrom(
                        backgroundColor: kDarkGreen,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
                        elevation: 0),
                    child: const Text('Save', style: TextStyle(color: Colors.white, fontSize: 18)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WellnessCard extends StatelessWidget {
  final IconData icon;
  final String   title;
  final String?  subtitle;
  final Widget   child;
  const _WellnessCard({required this.icon, required this.title, this.subtitle, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 10)],
      ),
      child: Row(
        children: [
          Icon(icon, size: 26),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 17)),
                if (subtitle != null)
                  Text(subtitle!, style: const TextStyle(fontSize: 12, color: Colors.black54)),
              ],
            ),
          ),
          child,
        ],
      ),
    );
  }
}

class _NumberSpinner extends StatelessWidget {
  final int          value;
  final VoidCallback onUp;
  final VoidCallback onDown;
  final String       suffix;
  const _NumberSpinner({required this.value, required this.onUp, required this.onDown, required this.suffix});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('${value.toString().padLeft(2, '0')} $suffix', style: const TextStyle(fontSize: 20)),
        const SizedBox(width: 2),
        Column(
          children: [
            GestureDetector(onTap: onUp,   child: const Icon(Icons.keyboard_arrow_up,   size: 20)),
            GestureDetector(onTap: onDown, child: const Icon(Icons.keyboard_arrow_down, size: 20)),
          ],
        ),
      ],
    );
  }
}

class _WellnessSliderCard extends StatelessWidget {
  final IconData             icon;
  final String               title;
  final String               subtitle;
  final double               value;
  final String               minLabel, midLabel, maxLabel;
  final ValueChanged<double> onChanged;
  const _WellnessSliderCard({required this.icon, required this.title, required this.subtitle, required this.value, required this.minLabel, required this.midLabel, required this.maxLabel, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 10)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 24),
              const SizedBox(width: 10),
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,    style: const TextStyle(fontSize: 16)),
                  Text(subtitle, style: const TextStyle(fontSize: 12, color: Colors.black54)),
                ],
              )),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor:   Colors.black,
              inactiveTrackColor: Colors.black26,
              thumbColor:         Colors.black,
              overlayColor:       Colors.transparent,
              trackHeight:        2,
            ),
            child: Slider(value: value, onChanged: onChanged),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(minLabel, style: const TextStyle(fontSize: 11, color: Colors.black54)),
                Text(midLabel, style: const TextStyle(fontSize: 11, color: Colors.black54)),
                Text(maxLabel, style: const TextStyle(fontSize: 11, color: Colors.black54)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

//finance page
class FinancePage extends StatefulWidget {
  final AppState appState;
  const FinancePage({super.key, required this.appState});

  @override
  State<FinancePage> createState() => _FinancePageState();
}

class _FinancePageState extends State<FinancePage> {
  void _showAddTransactionDialog() {
    final nameCtrl   = TextEditingController();
    final amountCtrl = TextEditingController();
    bool  isExpense  = true;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Center(child: Text('Transaction', style: TextStyle(fontSize: 24))),
                const SizedBox(height: 20),
                const Text('Name'),
                const SizedBox(height: 8),
                _FormTextField(controller: nameCtrl, hint: 'Name'),
                const SizedBox(height: 14),
                const Text('Amount'),
                const SizedBox(height: 8),
                _FormTextField(controller: amountCtrl, hint: 'Amount',
                    keyboardType: const TextInputType.numberWithOptions(decimal: true)),
                const SizedBox(height: 14),
                Row(
                  children: [
                    const Text('Type: '),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: () => setS(() => isExpense = true),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: isExpense ? Colors.red[50] : Colors.white,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.red[300]!),
                        ),
                        child: const Text('Expense'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: () => setS(() => isExpense = false),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: !isExpense ? Colors.green[50] : Colors.white,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.green[300]!),
                        ),
                        child: const Text('Income'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 22),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(ctx),
                        style: OutlinedButton.styleFrom(
                            side: BorderSide(color: Colors.grey[300]!),
                            backgroundColor: Colors.grey[100],
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                        child: const Text('Cancel', style: TextStyle(color: Colors.black54)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () {
                          final rawAmt = double.tryParse(amountCtrl.text) ?? 0;
                          if (nameCtrl.text.trim().isNotEmpty && rawAmt != 0) {
                            widget.appState.addTransaction(TransactionModel(
                              name:   nameCtrl.text.trim(),
                              amount: isExpense ? -rawAmt.abs() : rawAmt.abs(),
                              date:   DateTime.now(),
                            ));
                          }
                          Navigator.pop(ctx);
                        },
                        style: ElevatedButton.styleFrom(
                            backgroundColor: kMedGreen,
                            elevation: 0,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                        child: const Text('Save', style: TextStyle(color: Colors.white)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[200],
      body: SafeArea(
        child: AnimatedBuilder(
          animation: widget.appState,
          builder: (context, _) {
            final transactions = widget.appState.transactions;
            final balance      = widget.appState.balance;
            final recent       = transactions.take(3).toList();

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
                  child: const Text('Finance', style: TextStyle(fontSize: 32)),
                ),
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(22),
                    decoration: BoxDecoration(color: kMedGreen, borderRadius: BorderRadius.circular(20)),
                    child: Column(
                      children: [
                        const Text('Current balance', style: TextStyle(color: Colors.white70, fontSize: 15)),
                        const SizedBox(height: 8),
                        Text('\$${balance.toStringAsFixed(2)}', style: const TextStyle(color: Colors.white, fontSize: 38)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Expanded(
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 16),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(color: Colors.grey[200], borderRadius: BorderRadius.circular(20)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('Recent Transactions', style: TextStyle(fontSize: 17)),
                            GestureDetector(
                              onTap: () => Navigator.push(context,
                                  MaterialPageRoute(builder: (_) => AllTransactionsPage(appState: widget.appState))),
                              child: const Text('View All', style: TextStyle(color: kDarkGreen, fontSize: 14)),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        if (transactions.isEmpty)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 20),
                            child: Center(child: Text('No transactions yet.', style: TextStyle(color: Colors.black45))),
                          )
                        else
                          ...recent.map((t) => _TransactionTile(transaction: t)),
                        const Spacer(),
                        SizedBox(
                          width: double.infinity, height: 52,
                          child: ElevatedButton.icon(
                            onPressed: _showAddTransactionDialog,
                            icon: const Icon(Icons.add_circle, color: Colors.white),
                            label: const Text('Add Transaction', style: TextStyle(color: Colors.white, fontSize: 17)),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: kDarkGreen,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
                              elevation: 0,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 14),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _TransactionTile extends StatelessWidget {
  final TransactionModel transaction;
  const _TransactionTile({required this.transaction});

  @override
  Widget build(BuildContext context) {
    final isPositive = transaction.amount >= 0;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14)),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(transaction.name, style: const TextStyle(fontSize: 16)),
              Text(transaction.dateLabel, style: const TextStyle(fontSize: 12, color: Colors.black54)),
            ],
          ),
          Text(
            '${isPositive ? '+' : ''}${transaction.amount.toStringAsFixed(2)} \$',
            style: TextStyle(fontSize: 16, color: isPositive ? kDarkGreen : Colors.black87),
          ),
        ],
      ),
    );
  }
}

class AllTransactionsPage extends StatelessWidget {
  final AppState appState;
  const AllTransactionsPage({super.key, required this.appState});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: AnimatedBuilder(
          animation: appState,
          builder: (context, _) {
            final transactions = appState.transactions;
            return Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  Row(
                    children: [
                      GestureDetector(onTap: () => Navigator.pop(context), child: const Icon(Icons.chevron_left, size: 28)),
                      const Expanded(child: Center(child: Text('Recent Transactions', style: TextStyle(fontSize: 22)))),
                      const SizedBox(width: 28),
                    ],
                  ),
                  const SizedBox(height: 14),
                  if (transactions.isEmpty)
                    const Expanded(child: Center(child: Text('No transactions yet.', style: TextStyle(color: Colors.black45))))
                  else
                    Expanded(
                      child: ListView.separated(
                        itemCount: transactions.length,
                        separatorBuilder: (context, index) => const SizedBox(height: 8),
                        itemBuilder: (ctx, i) => _TransactionTile(transaction: transactions[i]),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}


// AI Chatbot
class ChatMessage {
  final String text;
  final bool   isBot;
  ChatMessage({required this.text, required this.isBot});

  Map<String, dynamic> toJson() => {'text': text, 'isBot': isBot};
  factory ChatMessage.fromJson(Map<String, dynamic> j) =>
      ChatMessage(text: j['text'], isBot: j['isBot']);
}

class AiChatPage extends StatefulWidget {
  final AppState appState;
  const AiChatPage({super.key, required this.appState});

  @override
  State<AiChatPage> createState() => _AiChatPageState();
}

class _AiChatPageState extends State<AiChatPage> {
  final List<ChatMessage> _messages = [
    ChatMessage(text: 'Hello!\nHow can I help you today?', isBot: true),
  ];
  final _inputCtrl  = TextEditingController();
  final _scrollCtrl = ScrollController();
  bool  _isWaiting  = false;

  @override
  void initState() {
    super.initState();
    _loadTodaysHistory();
  }

  Future<void> _loadTodaysHistory() async {
    final prefs     = await SharedPreferences.getInstance();
    final today     = _todayKey();
    final savedDate = prefs.getString(kPrefChatDate);

    if (savedDate == today) {
      final raw = prefs.getString(kPrefChatHistory);
      if (raw != null) {
        final List decoded = jsonDecode(raw);
        final loaded = decoded.map((m) => ChatMessage.fromJson(Map<String, dynamic>.from(m))).toList();
        if (mounted) {
          setState(() {
            _messages.clear();
            _messages.addAll(loaded);
          });
        }
      }
    } else {
      await prefs.setString(kPrefChatDate, today);
      await _saveHistory();
    }
  }

  Future<void> _saveHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        kPrefChatHistory, jsonEncode(_messages.map((m) => m.toJson()).toList()));
  }

  String _todayKey() {
    final now = DateTime.now();
    return '${now.year}-${now.month}-${now.day}';
  }

  Future<void> _sendMessage() async {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty || _isWaiting) return;

    final newUserMessage = ChatMessage(text: text, isBot: false);
    final allMessages    = [..._messages, newUserMessage];

    setState(() {
      _messages.add(newUserMessage);
      _isWaiting = true;
    });
    _inputCtrl.clear();
    _scrollToBottom();

    final history = allMessages
        .skip(1)
        .where((m) => m.text != kChatErrorFallback)
        .map((m) => {
              'role':    m.isBot ? 'assistant' : 'user',
              'content': m.text,
            })
        .toList();

    final systemPrompt = AiService.buildChatSystemPrompt(widget.appState);

    final reply = await AiService.chat(
      systemPrompt: systemPrompt,
      history:      history,
    );

    if (mounted) {
      setState(() {
        _messages.add(ChatMessage(
          text:  reply ?? kChatErrorFallback,
          isBot: true,
        ));
        _isWaiting = false;
      });
      _saveHistory();
      _scrollToBottom();
    }
  }

  void _scrollToBottom() {
    Future.delayed(const Duration(milliseconds: 100), () {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
            _scrollCtrl.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
  padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
  child: Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      const SizedBox(width: 32),
      const Text('AI Chat', style: TextStyle(fontSize: 28)),
      GestureDetector(
        onTap: () async {
          setState(() {
            _messages.clear();
            _messages.add(ChatMessage(text: 'Hello!\nHow can I help you today?', isBot: true));
          });
          await _saveHistory();
        },
        child: const Icon(Icons.delete_outline, color: Colors.black45, size: 22),
      ),
    ],
  ),
),
            Expanded(
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                    color: Colors.grey[200], borderRadius: BorderRadius.circular(20)),
                child: ListView.builder(
                  controller: _scrollCtrl,
                  padding: const EdgeInsets.all(14),
                  itemCount: _messages.length + (_isWaiting ? 1 : 0),
                  itemBuilder: (ctx, i) {
                    if (_isWaiting && i == _messages.length) {
                      return const Padding(
                        padding: EdgeInsets.only(bottom: 12),
                        child: Row(
                          children: [
                            CircleAvatar(
                                radius: 18,
                                backgroundColor: Colors.white,
                                child: Icon(Icons.smart_toy_outlined, size: 18)),
                            SizedBox(width: 8),
                            _TypingIndicator(),
                          ],
                        ),
                      );
                    }

                    final msg = _messages[i];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Row(
                        mainAxisAlignment:
                            msg.isBot ? MainAxisAlignment.start : MainAxisAlignment.end,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (msg.isBot) ...[
                            Container(
                              width: 36, height: 36,
                              decoration: BoxDecoration(
                                  color: Colors.white,
                                  shape: BoxShape.circle,
                                  border: Border.all(color: Colors.black26)),
                              child: const Icon(Icons.smart_toy_outlined, size: 20),
                            ),
                            const SizedBox(width: 8),
                          ],
                          Flexible(
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                              decoration: BoxDecoration(
                                color: msg.isBot ? kMedGreen : const Color(0xFF3D3D3D),
                                borderRadius: BorderRadius.only(
                                  topLeft:     const Radius.circular(16),
                                  topRight:    const Radius.circular(16),
                                  bottomLeft:  Radius.circular(msg.isBot ? 4 : 16),
                                  bottomRight: Radius.circular(msg.isBot ? 16 : 4),
                                ),
                              ),
                              child: Text(msg.text,
                                  style: const TextStyle(color: Colors.white, fontSize: 14, height: 1.4)),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(26),
                        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.07), blurRadius: 8)],
                      ),
                      child: TextField(
                        controller: _inputCtrl,
                        enabled: !_isWaiting,
                        decoration: const InputDecoration(
                          hintText: 'Ask Something ...',
                          hintStyle: TextStyle(color: Colors.black38),
                          contentPadding: EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                          border: InputBorder.none,
                        ),
                        onSubmitted: (_) => _sendMessage(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: _sendMessage,
                    child: Container(
                      width: 44, height: 44,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.07), blurRadius: 8)],
                      ),
                      child: const Icon(Icons.send, color: Colors.black54, size: 20),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TypingIndicator extends StatefulWidget {
  const _TypingIndicator();

  @override
  State<_TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<_TypingIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 600))
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, child) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(color: kMedGreen, borderRadius: BorderRadius.circular(16)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Opacity(
                opacity: (i == (_ctrl.value * 3).floor() % 3) ? 1.0 : 0.3,
                child: Container(
                    width: 6, height: 6,
                    decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle)),
              ),
            );
          }),
        ),
      ),
    );
  }
}

// Insights screen to track overall progress

enum InsightTab { week, month, year }

class InsightsPage extends StatefulWidget {
  final AppState appState;
  const InsightsPage({super.key, required this.appState});

  @override
  State<InsightsPage> createState() => _InsightsPageState();
}

class _InsightsPageState extends State<InsightsPage> {
  InsightTab _tab      = InsightTab.week;
  String?    _aiSummaryText;
  bool       _aiSummaryLoading = false;

  int _weekOffset  = 0;
  int _monthOffset = 0;
  int _yearOffset  = 0;

  DateTime _weekStart() {
    final now      = DateTime.now();
    final todayMon = now.subtract(Duration(days: now.weekday - 1));
    final mon      = DateTime(todayMon.year, todayMon.month, todayMon.day);
    return mon.add(Duration(days: _weekOffset * 7));
  }

  DateTime _monthStart() {
    final now = DateTime.now();
    int y = now.year;
    int m = now.month + _monthOffset;
    while (m < 1)  { m += 12; y--; }
    while (m > 12) { m -= 12; y++; }
    return DateTime(y, m, 1);
  }

  DateTime _yearStart() => DateTime(DateTime.now().year + _yearOffset, 1, 1);

  List<DateTime> _datesInPeriod() {
    switch (_tab) {
      case InsightTab.week:
        final mon = _weekStart();
        return List.generate(7, (i) => mon.add(Duration(days: i)));
      case InsightTab.month:
        final ms = _monthStart();
        final daysInMonth = DateTime(ms.year, ms.month + 1, 0).day;
        return List.generate(daysInMonth, (i) => DateTime(ms.year, ms.month, i + 1));
      case InsightTab.year:
        final ys = _yearStart();
        return List.generate(12, (i) => DateTime(ys.year, i + 1, 1));
    }
  }

  String get _periodLabel {
    const months     = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    const fullMonths = ['January','February','March','April','May','June','July','August','September','October','November','December'];
    switch (_tab) {
      case InsightTab.week:
        final mon = _weekStart();
        final sun = mon.add(const Duration(days: 6));
        return '${months[mon.month-1]} ${mon.day} – ${months[sun.month-1]} ${sun.day}';
      case InsightTab.month:
        final ms = _monthStart();
        return '${fullMonths[ms.month-1]} ${ms.year}';
      case InsightTab.year:
        return '${_yearStart().year}';
    }
  }

  bool _isCurrentPeriod() {
    switch (_tab) {
      case InsightTab.week:  return _weekOffset  == 0;
      case InsightTab.month: return _monthOffset == 0;
      case InsightTab.year:  return _yearOffset  == 0;
    }
  }

  void _goBack() => setState(() {
    if (_tab == InsightTab.week)  _weekOffset--;
    if (_tab == InsightTab.month) _monthOffset--;
    if (_tab == InsightTab.year)  _yearOffset--;
  });

  void _goForward() {
    if (_isCurrentPeriod()) return;
    setState(() {
      if (_tab == InsightTab.week)  _weekOffset++;
      if (_tab == InsightTab.month) _monthOffset++;
      if (_tab == InsightTab.year)  _yearOffset++;
    });
  }

  List<String> _xLabels() {
    final dates = _datesInPeriod();
    switch (_tab) {
      case InsightTab.week:
        const dayNames = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
        return dayNames;
      case InsightTab.month:
        final picked = <String>[];
        for (int i = 0; i < dates.length; i++) {
          if (i == 0 || dates[i].day % 5 == 0 || i == dates.length - 1) {
            picked.add('${dates[i].day}');
          }
        }
        return picked;
      case InsightTab.year:
        const abbr = ['J','F','M','A','M','J','J','A','S','O','N','D'];
        return abbr;
    }
  }

  List<DateTime> _sampledDates() {
    final dates = _datesInPeriod();
    switch (_tab) {
      case InsightTab.week:
        return dates;
      case InsightTab.month:
        final sampled = <DateTime>[];
        for (int i = 0; i < dates.length; i++) {
          if (i == 0 || dates[i].day % 5 == 0 || i == dates.length - 1) {
            sampled.add(dates[i]);
          }
        }
        return sampled;
      case InsightTab.year:
        return dates;
    }
  }

  double _avgForMonth(DateTime monthStart, String type) {
    final daysInMonth = DateTime(monthStart.year, monthStart.month + 1, 0).day;
    double sum   = 0;
    int    count = 0;
    for (int d = 1; d <= daysInMonth; d++) {
      final entry = widget.appState.wellnessForDate(DateTime(monthStart.year, monthStart.month, d));
      if (entry != null) {
        double val = 0;
        if (type == 'sleep')  val = (entry.sleepH + entry.sleepM / 60.0).clamp(0, 12);
        if (type == 'stress') val = (entry.stress * 10).clamp(0, 10);
        if (type == 'energy') val = (entry.energy * 10).clamp(0, 10);
        sum += val;
        count++;
      }
    }
    return count > 0 ? sum / count : 0;
  }

  List<double> _buildWellnessData(String type) {
    final sampled = _sampledDates();
    return sampled.map((d) {
      if (_tab == InsightTab.year) {
        return _avgForMonth(d, type);
      }
      final entry = widget.appState.wellnessForDate(d);
      if (entry == null) return 0.0;
      if (type == 'sleep')  return (entry.sleepH + entry.sleepM / 60.0).clamp(0.0, 12.0);
      if (type == 'stress') return (entry.stress * 10).clamp(0.0, 10.0);
      if (type == 'energy') return (entry.energy * 10).clamp(0.0, 10.0);
      return 0.0;
    }).toList();
  }

  List<double> _buildHabitData() {
    final sampled  = _sampledDates();
    final todayKey = '${DateTime.now().year}-${DateTime.now().month}-${DateTime.now().day}';
    final todayRate = widget.appState.habitCompletionRate * 100;

    return sampled.map((d) {
      final key = '${d.year}-${d.month}-${d.day}';
      if (_tab == InsightTab.year) {
        final now = DateTime.now();
        if (d.year == now.year && d.month == now.month) return todayRate;
        return 0.0;
      }
      if (key == todayKey) return todayRate;
      return 0.0;
    }).toList();
  }

  List<double> _buildFinanceData() {
    final sampled = _sampledDates();
    return sampled.map((d) {
      DateTime cutoff;
      if (_tab == InsightTab.year) {
        final daysInMonth = DateTime(d.year, d.month + 1, 0).day;
        cutoff = DateTime(d.year, d.month, daysInMonth, 23, 59, 59);
      } else {
        cutoff = DateTime(d.year, d.month, d.day, 23, 59, 59);
      }
      return widget.appState.transactions
          .where((t) => t.date.isBefore(cutoff) || t.date.isAtSameMomentAs(cutoff))
          .fold(0.0, (sum, t) => sum + t.amount);
    }).toList();
  }

  // Uses aggregated period data, not just today
  Future<void> _fetchAiSummary() async {
    setState(() => _aiSummaryLoading = true);
    final prompt = AiService.buildInsightsSummaryPrompt(widget.appState, _datesInPeriod());
    final result = await AiService.getInsight(prompt);
    if (mounted) setState(() { _aiSummaryText = result; _aiSummaryLoading = false; });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: AnimatedBuilder(
          animation: widget.appState,
          builder: (context, _) {
            final hasAnyData = widget.appState.wellnessData.isNotEmpty ||
                widget.appState.habits.isNotEmpty ||
                widget.appState.transactions.isNotEmpty;

            final xLabels     = _xLabels();
            final sleepData   = _buildWellnessData('sleep');
            final stressData  = _buildWellnessData('stress');
            final energyData  = _buildWellnessData('energy');
            final habitData   = _buildHabitData();
            final financeData = _buildFinanceData();

            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Progress', style: TextStyle(fontSize: 32)),
                  const Text('Your journey over time', style: TextStyle(fontSize: 15, color: Colors.black54)),
                  const SizedBox(height: 14),
                  Container(
                    height: 46,
                    decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(26)),
                    child: Row(
                      children: InsightTab.values.map((tab) {
                        final labels   = ['Week', 'Month', 'Year'];
                        final idx      = tab.index;
                        final selected = _tab == tab;
                        return Expanded(
                          child: GestureDetector(
                            onTap: () => setState(() => _tab = tab),
                            child: Container(
                              decoration: BoxDecoration(
                                color: selected ? kDarkGreen : Colors.transparent,
                                borderRadius: BorderRadius.circular(26),
                              ),
                              alignment: Alignment.center,
                              child: Text(labels[idx],
                                  style: TextStyle(
                                      color: selected ? Colors.white : Colors.black54,
                                      fontSize: 15)),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      GestureDetector(
                        onTap: _goBack,
                        child: Container(
                          width: 36, height: 36,
                          decoration: BoxDecoration(color: Colors.grey[200], borderRadius: BorderRadius.circular(10)),
                          child: const Icon(Icons.chevron_left, color: Colors.black54),
                        ),
                      ),
                      Expanded(
                        child: Center(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.calendar_today_outlined, size: 14, color: Colors.black45),
                              const SizedBox(width: 6),
                              Text(_periodLabel,
                                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                            ],
                          ),
                        ),
                      ),
                      GestureDetector(
                        onTap: _isCurrentPeriod() ? null : _goForward,
                        child: Container(
                          width: 36, height: 36,
                          decoration: BoxDecoration(
                              color: _isCurrentPeriod() ? Colors.grey[100] : Colors.grey[200],
                              borderRadius: BorderRadius.circular(10)),
                          child: Icon(Icons.chevron_right,
                              color: _isCurrentPeriod() ? Colors.black26 : Colors.black54),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),

                  if (!hasAnyData)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(color: Colors.grey[100], borderRadius: BorderRadius.circular(16)),
                      child: const Text(
                        'Start logging your habits, wellness, and transactions to see your progress charts here.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.black45, fontSize: 15, height: 1.6),
                      ),
                    )
                  else ...[
                    _ChartCard(
                      title: 'Habit Progress (%)',
                      child: _SimpleLineChart(
                          labels: xLabels,
                          data:   habitData,
                          color:  kDarkGreen,
                          maxY:   100),
                    ),
                    const SizedBox(height: 10),
                    _ChartCard(
                      title: 'Wellness Trends',
                      legend: Wrap(spacing: 8, children: const [
                        _LegendDot(color: Colors.blue,   label: 'Sleep (hrs)'),
                        _LegendDot(color: kDarkGreen,    label: 'Stress /10'),
                        _LegendDot(color: Colors.orange, label: 'Energy /10'),
                      ]),
                      child: _MultiLineChart(
                          labels:     xLabels,
                          sleepData:  sleepData,
                          stressData: stressData,
                          energyData: energyData),
                    ),
                    const SizedBox(height: 10),
                    _ChartCard(
                      title: 'Balance Over Time (\$)',
                      child: _SignedLineChart(
                          labels: xLabels,
                          data:   financeData),
                    ),
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 8)],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text('AI Summary', style: TextStyle(fontSize: 17)),
                              GestureDetector(
                                onTap: _fetchAiSummary,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(color: kCardGreen, borderRadius: BorderRadius.circular(20)),
                                  child: const Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.auto_awesome_outlined, size: 14, color: kDarkGreen),
                                      SizedBox(width: 4),
                                      Text('Generate', style: TextStyle(fontSize: 12, color: kDarkGreen)),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          if (_aiSummaryLoading)
                            const Row(children: [
                              SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: kMedGreen)),
                              SizedBox(width: 8),
                              Text('Analyzing your data…', style: TextStyle(color: Colors.black54, fontSize: 13)),
                            ])
                          else
                            Text(
                              _aiSummaryText ?? 'Tap "Generate" to get a personalized AI summary of your progress.',
                              style: const TextStyle(fontSize: 14, height: 1.5, color: Colors.black87),
                            ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _LegendDot extends StatelessWidget {
  final Color  color;
  final String label;
  const _LegendDot({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 9, height: 9, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
      const SizedBox(width: 4),
      Text(label, style: const TextStyle(fontSize: 10)),
    ]);
  }
}

class _ChartCard extends StatelessWidget {
  final String  title;
  final Widget? legend;
  final Widget  child;
  const _ChartCard({required this.title, this.legend, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 8)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontSize: 15)),
          if (legend != null) ...[const SizedBox(height: 6), legend!],
          const SizedBox(height: 6),
          child,
        ],
      ),
    );
  }
}

class _SimpleLineChart extends StatelessWidget {
  final List<String> labels;
  final List<double> data;
  final Color        color;
  final double       maxY;
  const _SimpleLineChart({required this.labels, required this.data, required this.color, this.maxY = 0});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 130,
      child: CustomPaint(
        painter: _LineChartPainter(labels: labels, data: data, color: color, fixedMaxY: maxY),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _LineChartPainter extends CustomPainter {
  final List<String> labels;
  final List<double> data;
  final Color        color;
  final double       fixedMaxY;
  _LineChartPainter({required this.labels, required this.data, required this.color, this.fixedMaxY = 0});

  @override
  void paint(Canvas canvas, Size size) {
    const leftPad   = 38.0;
    const bottomPad = 22.0;
    final w = size.width - leftPad;
    final h = size.height - bottomPad;
    final n = data.length;
    if (n < 2) return;

    final maxVal = fixedMaxY > 0 ? fixedMaxY : (data.reduce((a, b) => a > b ? a : b) * 1.2);
    final topVal = maxVal < 1 ? 10.0 : maxVal;

    final gridPaint = Paint()..color = Colors.black12..strokeWidth = 0.5;
    final linePaint = Paint()..color = color..strokeWidth = 2.5..style = PaintingStyle.stroke..strokeCap = StrokeCap.round;
    final dotPaint  = Paint()..color = color..style = PaintingStyle.fill;
    const ts = TextStyle(color: Colors.black54, fontSize: 9);

    for (int i = 0; i <= 4; i++) {
      final y   = h - (h * i / 4);
      canvas.drawLine(Offset(leftPad, y), Offset(size.width, y), gridPaint);
      final val = (topVal * i / 4).round();
      _textPainter('$val', ts).paint(canvas, Offset(0, y - 6));
    }

    final points = List.generate(n, (i) {
      final x = leftPad + (w * i / (n - 1));
      final y = topVal == 0 ? h : h - (h * data[i] / topVal);
      return Offset(x, y.clamp(0.0, h));
    });

    final areaPath = Path()..moveTo(points[0].dx, h);
    for (final p in points) {
  areaPath.lineTo(p.dx, p.dy);
}
    areaPath..lineTo(points.last.dx, h)..close();
    canvas.drawPath(areaPath, Paint()
      ..shader = LinearGradient(
        colors: [color.withValues(alpha: 0.18), color.withValues(alpha: 0.0)],
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
      ).createShader(Rect.fromLTWH(0, 0, size.width, h)));

    final path = Path()..moveTo(points[0].dx, points[0].dy);
    for (int i = 1; i < points.length; i++) {
      path.lineTo(points[i].dx, points[i].dy);
    }
    canvas.drawPath(path, linePaint);

    for (int i = 0; i < points.length; i++) {
      if (data[i] > 0) {
        canvas.drawCircle(points[i], 3.5, dotPaint);
        canvas.drawCircle(points[i], 3.5, Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 1.5);
      }
    }

    final labelStep = n <= 7 ? 1 : (n / 7).ceil();
    for (int i = 0; i < n; i++) {
      if (i % labelStep != 0 && i != n - 1) continue;
      final x  = leftPad + (w * i / (n - 1));
      final tp = _textPainter(labels[i < labels.length ? i : labels.length - 1], ts);
      tp.paint(canvas, Offset(x - tp.width / 2, size.height - bottomPad + 3));
    }
  }

  TextPainter _textPainter(String text, TextStyle style) {
    final tp = TextPainter(text: TextSpan(text: text, style: style), textDirection: TextDirection.ltr)..layout();
    return tp;
  }

  @override
  bool shouldRepaint(_) => true;
}

class _SignedLineChart extends StatelessWidget {
  final List<String> labels;
  final List<double> data;
  const _SignedLineChart({required this.labels, required this.data});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 130,
      child: CustomPaint(
        painter: _SignedLineChartPainter(labels: labels, data: data),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _SignedLineChartPainter extends CustomPainter {
  final List<String> labels;
  final List<double> data;
  _SignedLineChartPainter({required this.labels, required this.data});

  @override
  void paint(Canvas canvas, Size size) {
    const leftPad   = 48.0;
    const bottomPad = 22.0;
    final w = size.width - leftPad;
    final h = size.height - bottomPad;
    final n = data.length;
    if (n < 2) return;

    final maxVal = data.fold<double>(0, (m, v) => v > m ? v : m);
    final minVal = data.fold<double>(0, (m, v) => v < m ? v : m);
    final range  = (maxVal - minVal).abs();
    final topY   = maxVal + (range * 0.15);
    final botY   = minVal - (range * 0.15);
    final span   = (topY - botY) == 0 ? 1.0 : (topY - botY);

    double toCanvas(double val) => h - (h * (val - botY) / span);

    final gridPaint = Paint()..color = Colors.black12..strokeWidth = 0.5;
    final zeroPaint = Paint()..color = Colors.black26..strokeWidth = 1;
    final linePaint = Paint()
      ..color = kDarkGreen..strokeWidth = 2.5..style = PaintingStyle.stroke..strokeCap = StrokeCap.round;
    const ts = TextStyle(color: Colors.black54, fontSize: 9);

    for (int i = 0; i <= 4; i++) {
      final val   = botY + (span * i / 4);
      final y     = h - (h * i / 4);
      canvas.drawLine(Offset(leftPad, y), Offset(size.width, y), gridPaint);
      final label = val >= 1000  ? '\$${(val / 1000).toStringAsFixed(1)}k'
                  : val <= -1000 ? '-\$${(-val / 1000).toStringAsFixed(1)}k'
                  : '\$${val.toStringAsFixed(0)}';
      _tp(label, ts).paint(canvas, Offset(0, y - 6));
    }

    if (botY < 0 && topY > 0) {
      final zeroY = toCanvas(0);
      canvas.drawLine(Offset(leftPad, zeroY), Offset(size.width, zeroY), zeroPaint);
    }

    final points = List.generate(n, (i) {
      final x = leftPad + (w * i / (n - 1));
      final y = toCanvas(data[i]).clamp(0.0, h);
      return Offset(x, y);
    });

    final path = Path()..moveTo(points[0].dx, points[0].dy);
    for (int i = 1; i < points.length; i++) {
      path.lineTo(points[i].dx, points[i].dy);
    }
    canvas.drawPath(path, linePaint);

    for (int i = 0; i < points.length; i++) {
      if (data[i] != 0) {
        canvas.drawCircle(points[i], 3.5, Paint()..color = kDarkGreen);
        canvas.drawCircle(points[i], 3.5, Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 1.5);
      }
    }

    final labelStep = n <= 7 ? 1 : (n / 7).ceil();
    for (int i = 0; i < n; i++) {
      if (i % labelStep != 0 && i != n - 1) continue;
      final x  = leftPad + (w * i / (n - 1));
      final tp = _tp(labels[i < labels.length ? i : labels.length - 1], ts);
      tp.paint(canvas, Offset(x - tp.width / 2, size.height - bottomPad + 3));
    }
  }

  TextPainter _tp(String text, TextStyle style) {
    final tp = TextPainter(text: TextSpan(text: text, style: style), textDirection: TextDirection.ltr)..layout();
    return tp;
  }

  @override
  bool shouldRepaint(_) => true;
}

class _MultiLineChart extends StatelessWidget {
  final List<String> labels;
  final List<double> sleepData;
  final List<double> stressData;
  final List<double> energyData;
  const _MultiLineChart({required this.labels, required this.sleepData, required this.stressData, required this.energyData});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 130,
      child: CustomPaint(
        painter: _MultiLineChartPainter(labels: labels, sleepData: sleepData, stressData: stressData, energyData: energyData),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _MultiLineChartPainter extends CustomPainter {
  final List<String> labels;
  final List<double> sleepData;
  final List<double> stressData;
  final List<double> energyData;
  _MultiLineChartPainter({required this.labels, required this.sleepData, required this.stressData, required this.energyData});

  @override
  void paint(Canvas canvas, Size size) {
    const leftPad   = 30.0;
    const bottomPad = 22.0;
    final w = size.width - leftPad;
    final h = size.height - bottomPad;
    final n = labels.length;
    if (n < 2) return;

    final gridPaint = Paint()..color = Colors.black12..strokeWidth = 0.5;
    const ts = TextStyle(color: Colors.black54, fontSize: 9);

    for (int i = 0; i <= 4; i++) {
      final y = h - (h * i / 4);
      canvas.drawLine(Offset(leftPad, y), Offset(size.width, y), gridPaint);
      _tp('${(12 * i / 4).round()}', ts).paint(canvas, Offset(0, y - 6));
    }

    void drawSeries(List<double> data, Color color, double scale) {
      if (data.isEmpty || data.length < 2) return;
      final paint    = Paint()..color = color..strokeWidth = 2..style = PaintingStyle.stroke..strokeCap = StrokeCap.round;
      final dotPaint = Paint()..color = color;
      final useN     = data.length < n ? data.length : n;
      final points   = List.generate(useN, (i) {
        final x = leftPad + (w * i / (n - 1));
        final y = h - (h * (data[i] / scale).clamp(0.0, 1.0));
        return Offset(x, y);
      });
      final path = Path()..moveTo(points[0].dx, points[0].dy);
      for (int i = 1; i < points.length; i++) {
        path.lineTo(points[i].dx, points[i].dy);
      }
      canvas.drawPath(path, paint);
      for (int i = 0; i < points.length; i++) {
        if (data[i] > 0) canvas.drawCircle(points[i], 2.5, dotPaint);
      }
    }

    drawSeries(sleepData,  Colors.blue,   12);
    drawSeries(energyData, Colors.orange, 12);
    drawSeries(stressData, kDarkGreen,    12);

    final labelStep = n <= 7 ? 1 : (n / 7).ceil();
    for (int i = 0; i < n; i++) {
      if (i % labelStep != 0 && i != n - 1) continue;
      final x  = leftPad + (w * i / (n - 1));
      final tp = _tp(labels[i], ts);
      tp.paint(canvas, Offset(x - tp.width / 2, size.height - bottomPad + 3));
    }
  }

  TextPainter _tp(String text, TextStyle style) {
    final tp = TextPainter(text: TextSpan(text: text, style: style), textDirection: TextDirection.ltr)..layout();
    return tp;
  }

  @override
  bool shouldRepaint(_) => true;
}

// Cycle tracking
class CyclePage extends StatefulWidget {
  final AppState appState;
  const CyclePage({super.key, required this.appState});

  @override
  State<CyclePage> createState() => _CyclePageState();
}

class _CyclePageState extends State<CyclePage> {
  final _symptomCtrl = TextEditingController();

  void _showCycleSetupDialog() {
    int       tempMenstrual = widget.appState.menstrualDays;
    int       tempCycle     = widget.appState.cycleDays;
    DateTime? tempStart     = widget.appState.lastPeriodStart;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Center(child: Text('Set Up Your Cycle', style: TextStyle(fontSize: 22))),
                const SizedBox(height: 20),
                const Text('When did your last period start?'),
                const SizedBox(height: 8),
                GestureDetector(
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: ctx,
                      initialDate: tempStart ?? DateTime.now(),
                      firstDate:   DateTime.now().subtract(const Duration(days: 60)),
                      lastDate:    DateTime.now(),
                      builder: (ctx, child) => Theme(
                        data: ThemeData(colorScheme: const ColorScheme.light(primary: kDarkGreen, onPrimary: Colors.white)),
                        child: child!,
                      ),
                    );
                    if (picked != null) setS(() => tempStart = picked);
                  },
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(border: Border.all(color: kMedGreen), borderRadius: BorderRadius.circular(14)),
                    child: Row(
                      children: [
                        const Icon(Icons.calendar_today_outlined, color: kDarkGreen),
                        const SizedBox(width: 10),
                        Text(
                          tempStart != null
                              ? '${_monthName(tempStart!.month)} ${tempStart!.day}, ${tempStart!.year}'
                              : 'Select date',
                          style: TextStyle(color: tempStart != null ? Colors.black : Colors.black38, fontSize: 15),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                const Text('Menstrual days'),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Text('$tempMenstrual days', style: const TextStyle(fontSize: 20)),
                    const SizedBox(width: 10),
                    _CircleIconButton(icon: Icons.add,    onTap: () => setS(() => tempMenstrual = (tempMenstrual + 1).clamp(1, 10))),
                    const SizedBox(width: 6),
                    _CircleIconButton(icon: Icons.remove, onTap: () => setS(() => tempMenstrual = (tempMenstrual - 1).clamp(1, 10))),
                  ],
                ),
                const SizedBox(height: 16),
                const Text('Cycle length (days)'),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Text('$tempCycle days', style: const TextStyle(fontSize: 20)),
                    const SizedBox(width: 10),
                    _CircleIconButton(icon: Icons.add,    onTap: () => setS(() => tempCycle = (tempCycle + 1).clamp(20, 45))),
                    const SizedBox(width: 6),
                    _CircleIconButton(icon: Icons.remove, onTap: () => setS(() => tempCycle = (tempCycle - 1).clamp(20, 45))),
                  ],
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(ctx),
                        style: OutlinedButton.styleFrom(
                            side: BorderSide(color: Colors.grey[300]!),
                            backgroundColor: Colors.grey[100],
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                        child: const Text('Cancel', style: TextStyle(color: Colors.black54)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () {
                          widget.appState.setCycleDays(tempMenstrual, tempCycle);
                          if (tempStart != null) widget.appState.setLastPeriodStart(tempStart!);
                          Navigator.pop(ctx);
                        },
                        style: ElevatedButton.styleFrom(
                            backgroundColor: kMedGreen,
                            elevation: 0,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                        child: const Text('Save', style: TextStyle(color: Colors.white)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _monthName(int m) {
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return months[m - 1];
  }

  String _computeNextPeriodDate(AppState appState) {
    final next = appState.nextPeriodDate;
    if (next == null) return '—';
    return '${_monthName(next.month)} ${next.day}, ${next.year}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: AnimatedBuilder(
          animation: widget.appState,
          builder: (context, _) {
            final appState = widget.appState;
            final cycleDay = appState.currentCycleDay;
            final phase    = appState.currentPhase;
            final tip      = appState.phaseTip;
            final hasSetup = appState.lastPeriodStart != null;

            final progressFraction = appState.cycleDays > 0
                ? (cycleDay.clamp(1, appState.cycleDays) / appState.cycleDays)
                : 0.0;

            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Cycle Tracking', style: TextStyle(fontSize: 30)),
                          Text('Understand your body patterns', style: TextStyle(fontSize: 14, color: Colors.black54)),
                        ],
                      ),
                      GestureDetector(
                        onTap: _showCycleSetupDialog,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(color: kCardGreen, borderRadius: BorderRadius.circular(20)),
                          child: const Row(children: [
                            Icon(Icons.settings_outlined, size: 16),
                            SizedBox(width: 4),
                            Text('Setup', style: TextStyle(fontSize: 13)),
                          ]),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  if (!hasSetup)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(color: kCardGreen, borderRadius: BorderRadius.circular(20)),
                      child: Column(
                        children: [
                          const Icon(Icons.water_drop_outlined, size: 40, color: kDarkGreen),
                          const SizedBox(height: 10),
                          const Text('Set up your cycle to get started', style: TextStyle(fontSize: 16)),
                          const SizedBox(height: 4),
                          const Text('Tap Setup to enter your cycle details.',
                              textAlign: TextAlign.center,
                              style: TextStyle(fontSize: 13, color: Colors.black54)),
                          const SizedBox(height: 14),
                          ElevatedButton(
                            onPressed: _showCycleSetupDialog,
                            style: ElevatedButton.styleFrom(
                                backgroundColor: kDarkGreen,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                                elevation: 0),
                            child: const Text('Set Up Now', style: TextStyle(color: Colors.white)),
                          ),
                        ],
                      ),
                    )
                  else ...[
                    Center(
                      child: SizedBox(
                        width: 180, height: 180,
                        child: CustomPaint(
                          painter: _CycleRingPainter(progress: progressFraction, phase: phase),
                          child: Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text('Day $cycleDay',
                                    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
                                Text(phase, style: const TextStyle(fontSize: 16, color: kMedGreen)),
                                Text('of ${appState.cycleDays}',
                                    style: const TextStyle(fontSize: 12, color: Colors.black45)),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(color: kCardGreen, borderRadius: BorderRadius.circular(16)),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Symptoms', style: TextStyle(fontSize: 19)),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 14),
                                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(26)),
                                  child: TextField(
                                    controller: _symptomCtrl,
                                    decoration: const InputDecoration(
                                      hintText: 'What are you experiencing?',
                                      border: InputBorder.none,
                                    ),
                                    onSubmitted: (v) {
                                      if (v.trim().isNotEmpty) {
                                        appState.addCycleSymptom(v.trim());
                                        _symptomCtrl.clear();
                                      }
                                    },
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              GestureDetector(
                                onTap: () {
                                  final text = _symptomCtrl.text.trim();
                                  if (text.isNotEmpty) {
                                    appState.addCycleSymptom(text);
                                    _symptomCtrl.clear();
                                  }
                                },
                                child: Container(
                                  width: 42, height: 42,
                                  decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.white),
                                  child: const Icon(Icons.send, size: 18),
                                ),
                              ),
                            ],
                          ),
                          if (appState.cycleSymptoms.isNotEmpty) ...[
                            const SizedBox(height: 10),
                            Wrap(
                              spacing: 6, runSpacing: 4,
                              children: appState.cycleSymptoms.map((s) => Chip(
                                label: Text(s, style: const TextStyle(fontSize: 12)),
                                backgroundColor: Colors.white,
                                padding: EdgeInsets.zero,
                                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              )).toList(),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 10)],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Tips for $phase phase', style: const TextStyle(fontSize: 17)),
                          const SizedBox(height: 6),
                          Text(tip, style: const TextStyle(fontSize: 14, height: 1.5)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 10)],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text('Personal Cycle', style: TextStyle(fontSize: 17)),
                              GestureDetector(
                                onTap: _showCycleSetupDialog,
                                child: const Text('Edit', style: TextStyle(color: kDarkGreen, fontSize: 14)),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text('Menstrual days', style: TextStyle(fontSize: 13, color: Colors.black54)),
                                  Text('${appState.menstrualDays} days', style: const TextStyle(fontSize: 20)),
                                ],
                              )),
                              Expanded(child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text('Cycle length', style: TextStyle(fontSize: 13, color: Colors.black54)),
                                  Text('${appState.cycleDays} days', style: const TextStyle(fontSize: 20)),
                                ],
                              )),
                            ],
                          ),
                          if (appState.lastPeriodStart != null) ...[
                            const SizedBox(height: 6),
                            Text(
                              'Last period: ${_monthName(appState.lastPeriodStart!.month)} ${appState.lastPeriodStart!.day}',
                              style: const TextStyle(fontSize: 12, color: Colors.black45),
                            ),
                            Text(
                              'Next period: ${_computeNextPeriodDate(appState)}',
                              style: const TextStyle(fontSize: 12, color: kDarkGreen),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _CycleRingPainter extends CustomPainter {
  final double progress;
  final String phase;
  const _CycleRingPainter({required this.progress, required this.phase});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width / 2) - 12;

    final bgPaint = Paint()
      ..color       = kLightGreen.withValues(alpha: 0.5)
      ..style       = PaintingStyle.stroke
      ..strokeWidth = 14
      ..strokeCap   = StrokeCap.round;

    canvas.drawCircle(center, radius, bgPaint);

    if (progress > 0) {
      final fgPaint = Paint()
        ..color       = kDarkGreen
        ..style       = PaintingStyle.stroke
        ..strokeWidth = 14
        ..strokeCap   = StrokeCap.round;

      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -1.5707963,
        2 * 3.14159265 * progress,
        false,
        fgPaint,
      );
    }
  }

  @override
  bool shouldRepaint(_CycleRingPainter old) => old.progress != progress;
}

class _CircleIconButton extends StatelessWidget {
  final IconData     icon;
  final VoidCallback onTap;
  const _CircleIconButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 30, height: 30,
        decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFF5C5C5C)),
        child: Icon(icon, color: Colors.white, size: 16),
      ),
    );
  }
}

class ProfilePage extends StatefulWidget {
  final AppState appState;
  const ProfilePage({super.key, required this.appState});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {

  Future<void> _logout() async {
    await FirebaseAuth.instance.signOut();
    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const WelcomePage()),
        (route) => false,
      );
    }
  }

  Future<void> _handleNotificationToggle(bool enabled) async {
    if (enabled) {
      final granted = await NotificationService.requestPermission();
      if (!granted) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Notification permission denied. Enable it in device Settings.')),
          );
        }
        return;
      }
      await NotificationService.showNotification(
        id:    1,
        title: 'Thrive Reminders On 🌿',
        body:  "You'll get daily reminders for habits and wellness logging.",
      );
      widget.appState.setNotificationsEnabled(true);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Notifications enabled')));
      }
    } else {
      await NotificationService.cancel(1);
      widget.appState.setNotificationsEnabled(false);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Notifications disabled')));
      }
    }
  }

  Future<void> _pickProfilePhoto() async {
    final picker = ImagePicker();
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined),
              title: const Text('Take a photo'),
              onTap: () async {
                Navigator.pop(ctx);
                final xFile = await picker.pickImage(source: ImageSource.camera, imageQuality: 80);
                if (xFile != null) await widget.appState.setLocalProfilePhoto(xFile.path);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from gallery'),
              onTap: () async {
                Navigator.pop(ctx);
                final xFile = await picker.pickImage(source: ImageSource.gallery, imageQuality: 80);
                if (xFile != null) await widget.appState.setLocalProfilePhoto(xFile.path);
              },
            ),
            if (widget.appState.localProfilePhotoPath != null)
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.red),
                title: const Text('Remove photo', style: TextStyle(color: Colors.red)),
                onTap: () async {
                  Navigator.pop(ctx);
                  await widget.appState.setLocalProfilePhoto('');
                },
              ),
          ],
        ),
      ),
    );
  }

  // Clear data and delete account — AuthRouter handles navigation
  Future<void> _deleteAccount() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title:   const Text('Delete Account'),
        content: const Text('This action is permanent and cannot be undone. All your data will be lost. Are you sure?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete', style: TextStyle(color: Colors.red))),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await widget.appState.clearAllData();
      await FirebaseAuth.instance.currentUser?.delete();
      await GoogleSignIn().signOut();
      // authStateChanges fires null → AuthRouter shows WelcomePage
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      if (e.code == 'requires-recent-login') {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('For security, please log out and log in again before deleting your account.'),
            duration: Duration(seconds: 4),
          ),
        );
      } else {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message ?? 'Deletion failed.')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final user  = FirebaseAuth.instance.currentUser;
    final name  = user?.displayName ?? 'User';
    final email = user?.email ?? '';

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: AnimatedBuilder(
          animation: widget.appState,
          builder: (context, _) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Profile', style: TextStyle(fontSize: 32)),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      GestureDetector(
                        onTap: _pickProfilePhoto,
                        child: Stack(
                          children: [
                            _ProfileAvatar(
                              user: user,
                              localPhotoPath: widget.appState.localProfilePhotoPath,
                              radius: 39,
                            ),
                            Positioned(
                              bottom: 0, right: 0,
                              child: Container(
                                width: 26, height: 26,
                                decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: Colors.white,
                                    border: Border.all(color: Colors.black26)),
                                child: const Icon(Icons.camera_alt_outlined, size: 14),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(name,  style: const TextStyle(fontSize: 20), overflow: TextOverflow.ellipsis),
                            Text(email, style: const TextStyle(fontSize: 14, color: Colors.black54), overflow: TextOverflow.ellipsis),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  _SettingsToggle(
                    label:     'Enable Cycle Tracking',
                    value:     widget.appState.cycleEnabled,
                    onChanged: (v) => widget.appState.setCycleEnabled(v),
                  ),
                  const SizedBox(height: 10),
                  _SettingsToggle(
                    label:     'Notifications',
                    value:     widget.appState.notificationsEnabled,
                    onChanged: _handleNotificationToggle,
                  ),
                  if (widget.appState.notificationsEnabled)
                    const Padding(
                      padding: EdgeInsets.only(left: 4, bottom: 4, top: 4),
                      child: Text(
                        'You will receive daily reminders for habits and wellness logging.',
                        style: TextStyle(fontSize: 12, color: Colors.black45),
                      ),
                    ),
                  const Spacer(),
                  SizedBox(
                    width: double.infinity, height: 52,
                    child: OutlinedButton(
                      onPressed: _logout,
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Colors.red, width: 2),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                      child: const Text('Log Out', style: TextStyle(color: Colors.red, fontSize: 17)),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity, height: 48,
                    child: OutlinedButton(
                      onPressed: _deleteAccount,
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Colors.red, width: 1.2),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                      child: const Text('Delete Account', style: TextStyle(color: Colors.red, fontSize: 15)),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Center(
                    child: Text('This will permanently delete your account.',
                        style: TextStyle(fontSize: 11, color: Colors.red[200])),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _SettingsToggle extends StatelessWidget {
  final String             label;
  final bool               value;
  final ValueChanged<bool> onChanged;
  const _SettingsToggle({required this.label, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.07), blurRadius: 8)],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 15)),
          Switch(
            value:              value,
            onChanged:          onChanged,
            activeThumbColor:   kDarkGreen,
            inactiveThumbColor: Colors.white,
            inactiveTrackColor: Colors.black26,
          ),
        ],
      ),
    );
  }
}