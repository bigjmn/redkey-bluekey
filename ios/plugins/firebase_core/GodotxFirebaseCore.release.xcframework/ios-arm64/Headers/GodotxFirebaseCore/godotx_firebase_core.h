#ifndef GODOTX_FIREBASE_CORE_H
#define GODOTX_FIREBASE_CORE_H

#include "core/object/class_db.h"

class GodotxFirebaseCore : public Object {
    GDCLASS(GodotxFirebaseCore, Object);
    
private:
    static GodotxFirebaseCore* instance;
    bool is_initialized;
    
protected:
    static void _bind_methods();
    
public:
    static GodotxFirebaseCore* get_singleton();
    
    void initialize();
    bool is_ready() const;
    
    GodotxFirebaseCore();
    ~GodotxFirebaseCore();
};

#endif // GODOTX_FIREBASE_CORE_H

