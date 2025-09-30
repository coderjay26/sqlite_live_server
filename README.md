# SQLite Pro Web Interface

A powerful, feature-rich web interface for SQLite databases built with Dart and Flutter. This package provides a beautiful, responsive web UI to browse, query, and manage your SQLite databases directly from your Flutter applications.

## 🚀 Features

- **🔍 Database Browser**: Explore tables, schemas, and data with an intuitive interface
- **📊 Advanced Querying**: Execute SQL queries with syntax highlighting and formatting
- **🔄 Real-time Results**: Paginated results with search and filtering capabilities
- **📱 Responsive Design**: Works perfectly on desktop and mobile devices
- **⚡ Fast & Lightweight**: Built for performance with minimal overhead
- **🔒 Safe**: Runs locally, no data leaves your device
- **📋 Query History**: Track and reuse previous queries
- **📤 Export Data**: Export tables to JSON or CSV format
- **🔍 Schema Inspection**: Detailed table structure and relationships

## 📦 Installation

Add the required dependencies to your `pubspec.yaml`:

```yaml
dependencies:
  shelf: ^1.4.0
  shelf_router: ^1.1.0
  shelf_static: ^1.1.0
  shelf_web_socket: ^1.0.0
  web_socket_channel: ^2.4.0
  sqflite: ^2.3.0
  path_provider: ^2.1.0
  path: ^1.8.0
```

## 🛠️ Quick Start
1. Advanced Usage with Custom Configuration
```dart
import 'package:your_package/sqlite_service.dart';
import 'package:your_package/web_server.dart';

static Future<void> startIfNeeded() async {
  logJ('🔍 Debug: Starting server initialization...');
  
  try {
    logJ('🔍 Debug: Creating SQLiteService...');
    final dbService = SQLiteService();
    
    logJ('🔍 Debug: Initializing database...');
    await dbService.initDatabase('ravamate.db');
    
    logJ('🔍 Debug: Creating WebServer...');
    final webServer = WebServer(dbService, 
      port: 8080,                    // Custom port
      enableWebSocket: true          // Enable real-time updates
    );
    
    logJ('🔍 Debug: Starting server...');
    final success = await webServer.startServer();
    
    logJ('🔍 Debug: Server start result: $success');
  } catch (e, stackTrace) {
    logE('🚨 CRITICAL ERROR: $e');
    logE('📋 Stack trace: $stackTrace');
  }
}
```

3. Integration in Flutter App
```dart
class MyApp extends StatefulWidget {
  @override
  _MyAppState createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  @override
  void initState() {
    super.initState();
    _initializeServer();
  }

  Future<void> _initializeServer() async {
    // Only start in debug mode for safety
    if (kDebugMode) {
      await SqliteLiveServer.start(dbName: 'app_database.db');
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'My App with SQLite Browser',
      home: HomePage(),
    );
  }

  @override
  void dispose() {
    // Clean up when app closes
    if (kDebugMode) {
      SqliteLiveServer.stop();
    }
    super.dispose();
  }
}
```

## 🌐 Accessing the Web Interface
Once started, access the web interface at:

```
http://localhost:8080
```

Or if you're on the same network:

```
http://[YOUR_DEVICE_IP]:8080
```

The server will automatically detect and display your local IP address in the console.

## 📚 API Endpoints
The server provides the following REST API endpoints:

- GET /api/tables - List all tables
- GET /api/tables/:table/schema - Get table schema
- GET /api/tables/:table/info - Get table information
- GET /api/query?sql=... - Execute SQL query (GET)
- POST /api/query - Execute SQL query (POST)
- POST /api/tables/:table/data - Insert data
- PUT /api/tables/:table/data - Update data
- DELETE /api/tables/:table/data - Delete data
- GET /api/database/info - Get database information
- GET /api/export/:table - Export table data (JSON/CSV)
- GET /api/history - Get query history

## 🎯 Key Features in Detail
### Table Browser
- Scrollable table list with search functionality
- Real-time table statistics (row counts)
- One-click table selection and query generation
- Active table highlighting

### Query Interface
- SQL syntax templates for common operations (SELECT, INSERT, UPDATE, DELETE)
- Query formatting and validation
- Execution time tracking
- Query history with click-to-reuse
- EXPLAIN QUERY PLAN support

### Results Display
- Pagination: Handle large datasets efficiently (10, 25, 50, 100, 250 rows per page)
- Smart Display: Proper formatting for different data types (numbers, booleans, null values)
- JSON View: Raw JSON representation of results
- Schema Inspector: Detailed table structure information
- Responsive Tables: Horizontal scrolling for wide tables

### Data Management
- CRUD Operations: Create, read, update, delete data
- Export Capabilities: Export to JSON or CSV format
- Bulk Operations: Handle large datasets with pagination
- Real-time Updates: WebSocket support for live data

## ⚙️ Configuration Options
### WebServer Constructor Parameters
```dart
WebServer(
  dbService,           // Required: SQLiteService instance
  port: 8080,          // Optional: Port number (default: 8080)
  enableWebSocket: true // Optional: WebSocket for real-time updates
)
```

### SQLiteService Methods
```dart
final dbService = SQLiteService();

// Initialize with your database
await dbService.initDatabase('your_database.db');

// Available operations
List<String> tables = await dbService.getTables();
List<Map> data = await dbService.query('SELECT * FROM users');
int insertedId = await dbService.insert('users', {'name': 'John'});
int affectedRows = await dbService.update('users', {'name': 'Jane'}, where: 'id=1');
int deletedRows = await dbService.delete('users', where: 'id=1');
Map dbInfo = await dbService.getDatabaseInfo();
```

## 🎨 UI Components
### Sidebar
- Database information panel
- Searchable table list with scrollable container
- Table statistics and counts
- Clean, dark theme design

### Main Content Area
- Tabbed interface (Results, Schema, JSON View)
- Query editor with syntax templates
- Action buttons for common operations
- Real-time execution statistics

### Results Panel
- Paginated data tables
- Sortable columns
- Data type-specific formatting
- Export functionality

## 🔧 Troubleshooting
### Common Issues
**Port Already in Use**
```dart
// The server automatically tries alternative ports
final webServer = WebServer(dbService, port: 8080);
```

**Database Connection Issues**
```dart
// Ensure database is properly initialized
await dbService.initDatabase('your_database.db');
```

**Permission Denied**
- Make sure your app has network permissions
- Check if the port is available

**JavaScript Errors**
- Check browser console for detailed error messages
- Ensure all required CSS/JS resources are loading

### Debug Mode
Enable detailed logging by wrapping your initialization:

```dart
static Future<void> startIfNeeded() async {
  logJ('🔍 Debug: Starting server initialization...');
  
  try {
    logJ('🔍 Debug: Creating SQLiteService...');
    final dbService = SQLiteService();
    
    logJ('🔍 Debug: Initializing database...');
    await dbService.initDatabase('ravamate.db');
    
    logJ('🔍 Debug: Creating WebServer...');
    final webServer = WebServer(dbService, port: 8080);
    
    logJ('🔍 Debug: Starting server...');
    final success = await webServer.startServer();
    
    logJ('🔍 Debug: Server start result: $success');
  } catch (e, stackTrace) {
    logE('🚨 CRITICAL ERROR: $e');
    logE('📋 Stack trace: $stackTrace');
  }
}
```

## 📱 Mobile Considerations
### Performance
- Pagination prevents memory issues with large datasets
- Lazy loading of table data
- Efficient DOM rendering for smooth scrolling

### Security
- Only runs in debug mode by default
- Local network access only
- No external dependencies

### Responsive Design
- Mobile-optimized sidebar that collapses appropriately
- Touch-friendly interface elements
- Adaptive table layouts with horizontal scrolling

## 🔮 Future Enhancements
- Database visualization tools
- Advanced query builder
- Data import functionality
- User authentication
- Multiple database support
- Custom theme support
- Advanced filtering and sorting
- Data validation rules

## 🤝 Contributing
We welcome contributions! Please feel free to submit pull requests, report bugs, or suggest new features.

## 📄 License
This project is licensed under the MIT License - see the LICENSE file for details.

## 🙏 Acknowledgments
Powered by JJ Automation Solutions (Jay Fuego)

Built with ❤️ for the Flutter community.
