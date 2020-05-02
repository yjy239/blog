---
title: EventBus源码浅析
top: false
cover: false
date: 2019-06-04 17:54:32
img:
tag:
description:
author: yjy239
summary:
tags:
- Android
- Android 常用第三方库
---
# 背景
如果遇到问题请在：[https://www.jianshu.com/p/301edd6a2e61](https://www.jianshu.com/p/301edd6a2e61)
讨论
EventBus使我们常用的第三方库之一。可以说大部分Android应用都在用这个库在做通信，当然也有人认为EventBus过于解耦导致其无法很好的维护工程,而去使用本地广播作为信号传输方式。

# 正文
EventBus的使用这里就不继续赘述了，毕竟几乎大部分人都知道如何使用。EventBus本质上是一个基于观察者设计的总线事件处理。那么观察者设计模式必定会存在两个角色，一个是观察者，一个是被观察者。

从设计模式的角度上看，EventBus本身就是一个对所有的对象感兴趣并且注册到其中，然后能够通过post发送事件到EventBus中注册的对象中。

从这里面的描述，就大体知道,EventBus是一个观察者，通过register方法注册进来的对象是一个被观察者。同时EventBus是一个推模式的观察者设计。

虽然是观察者设计，但是并没有任何的接口暴露出来，需要观察者和被观察者去实现和继承，而是无感让事件推送到我们感兴趣的地方，这就是EventBus设计巧妙。其核心就是灵活运用反射去做完成了这一系列的行为，让EventBus中获得每个注册类中需要监听的时间类型，并且可以在post时候方便找到。

因为是通过反射处理而避免接口抽象，我们把整个UML设计图还原出来如下：
![eventbus.png](/images/eventbus.png)

EventBus的主要角色：
- EventBus 作为EventBus中对所有注册进来的对象都感兴趣的观察者
- subscriberMethodFinder EventBus扫描类信息的扫描器
 - Poster EventBus中切换线程的工作区的工具


开篇总结先到这里，本文会通过解析EventBus的register以及post的方法来浅析EventBus源码。

### EventBus 高级运用

提一句，EventBus到了3.0这个版本实际上已经支持编译时生成一个SubscriberInfoIndex的类，其作用就是在编译时扫描每一个类中加了@Subcirbe注解的方法，并且存到map中。

下面是个simple:
```
public class index implements SubscriberInfoIndex {
    private static final Map<Class<?>, SubscriberInfo> SUBSCRIBER_INDEX;

    static {
        SUBSCRIBER_INDEX = new HashMap<Class<?>, SubscriberInfo>();

        putIndex(new SimpleSubscriberInfo(MainActivity.class, true, new SubscriberMethodInfo[] {
            new SubscriberMethodInfo("handle", Event.class, ThreadMode.MAIN),
        }));

    }

    private static void putIndex(SubscriberInfo info) {
        SUBSCRIBER_INDEX.put(info.getSubscriberClass(), info);
    }

    @Override
    public SubscriberInfo getSubscriberInfo(Class<?> subscriberClass) {
        SubscriberInfo info = SUBSCRIBER_INDEX.get(subscriberClass);
        if (info != null) {
            return info;
        } else {
            return null;
        }
    }
}
```

我们能看到的是，这里有个关键的类SubscriberMethodInfo。里面保存的参数，从左到右依次是方法名字，方法中的参数类型，该方法在哪个线程接受的。

这样通过编译时生成的代码加入到map中，之后通过getSubscriberInfo获取map中的内容，就能获得类中的方法。这样就能避免运行时反射扫描整个类去找到需要的方法名。

接着再运行如下代码:
```
EventBus.builder().addIndex(new index()).installDefaultEventBus();
```
就能把这个index对象加入EventBus的全局缓存中，就能避免运行时反射扫描的性能消耗！


## register EventBus注册监听
直接看看当我们第一次使用EventBus的时候，需要在这个对象监的注册开始监听的方法
```
EventBus.getDefault().register(this);
```
从这里我们能够看到实际上EventBus是一个单例来管理全局。因此我们看看register的方法。

```
private static final EventBusBuilder DEFAULT_BUILDER = new EventBusBuilder();

public static EventBus getDefault() {
        if (defaultInstance == null) {
            synchronized (EventBus.class) {
                if (defaultInstance == null) {
                    defaultInstance = new EventBus();
                }
            }
        }
        return defaultInstance;
    }

public EventBus() {
        this(DEFAULT_BUILDER);
    }

```

从这里我们能够初步的看到当前实际上本质上第一次调用getDefault的时候会通过一个默认的Builder去确定EventBus的行为。



```
public void register(Object subscriber) {
        Class<?> subscriberClass = subscriber.getClass();
        List<SubscriberMethod> subscriberMethods = subscriberMethodFinder.findSubscriberMethods(subscriberClass);
        synchronized (this) {
            for (SubscriberMethod subscriberMethod : subscriberMethods) {
                subscribe(subscriber, subscriberMethod);
            }
        }
    }
```
在注册监听的方法，虽然看不到什么实质的方法。虽然在这一段代码看不出什么实质的东西，但是却能够看出EventBus是怎么把当前对象注册到eventbus进行对象的监听。

这一段代码就是注册思路主线。
- 1.首先通过subscriberMethodFinder扫描类里面添加了@Subscriber注解的方法，并且生成包含方法，类名信息的SubscriberMethod的队列，最后返回。
- 2.接着通过subscribe的方法，校验SubscriberMethod的合法性，最后添加到全局缓存数据结构中，等待调用。

因此EventBus的注册流程将会分为两步骤来解析:

### 1. subscriberMethodFinder 扫描类中合法的方法
在上述代码片段中，能够很轻易的看到了在EventBus存在这么一类SubscriberMethodFinder对注册进来的对象进行了扫描
```
List<SubscriberMethod> findSubscriberMethods(Class<?> subscriberClass) {
        List<SubscriberMethod> subscriberMethods = METHOD_CACHE.get(subscriberClass);
        if (subscriberMethods != null) {
            return subscriberMethods;
        }

        if (ignoreGeneratedIndex) {
            subscriberMethods = findUsingReflection(subscriberClass);
        } else {
            subscriberMethods = findUsingInfo(subscriberClass);
        }
        if (subscriberMethods.isEmpty()) {
            throw new EventBusException("Subscriber " + subscriberClass
                    + " and its super classes have no public methods with the @Subscribe annotation");
        } else {
            METHOD_CACHE.put(subscriberClass, subscriberMethods);
            return subscriberMethods;
        }
    }
```

看到的是，为了避免过度消耗性能，做过多的反射操作。实际上EventBus本身会对已经扫描过对象，把对象的class作为key值把里面的方法以及类型保存下来，当需再次查找的时候，就没有必要再度扫描了。

ignoreGeneratedIndex这个标志位，如果熟悉EventBusBuilder的构造方法的朋友一定知道，这个标志位实际上是可以设置的。这个标志位的作用在里面实际上就是是否忽略反射的方式去扫描类对象。是的话，则调用findUsingInfo 读取编译时生成的类和方法信息，否则就通过反射扫描类。

最后，能看到常见的解析，如果当我们加了register的方法，但是并没有扫描到任何的类，将会报错误。

ignoreGeneratedIndex的标志位默认为false，此时我们看看findUsingInfo的方法。

### findUsingInfo
```
private FindState prepareFindState() {
        synchronized (FIND_STATE_POOL) {
            for (int i = 0; i < POOL_SIZE; i++) {
                FindState state = FIND_STATE_POOL[i];
                if (state != null) {
                    FIND_STATE_POOL[i] = null;
                    return state;
                }
            }
        }
        return new FindState();
    }

private List<SubscriberMethod> findUsingInfo(Class<?> subscriberClass) {
        FindState findState = prepareFindState();
        findState.initForSubscriber(subscriberClass);
        while (findState.clazz != null) {
//获取缓存中的SubscriberInfo 数据
            findState.subscriberInfo = getSubscriberInfo(findState);
            if (findState.subscriberInfo != null) {
                SubscriberMethod[] array = findState.subscriberInfo.getSubscriberMethods();
                for (SubscriberMethod subscriberMethod : array) {
                    if (findState.checkAdd(subscriberMethod.method, subscriberMethod.eventType)) {
                        findState.subscriberMethods.add(subscriberMethod);
                    }
                }
            } else {
                findUsingReflectionInSingleClass(findState);
            }
            findState.moveToSuperclass();
        }
        return getMethodsAndRelease(findState);
    }
```
findState 是一个用于操作类扫描的封装类，为了性能优化，是有个大小为5的缓存池子缓存到内存，每一次需要都从里面获取，超出则生成新的。

#### getSubscriberInfo获取编译时生成的对象中的信息
```
private SubscriberInfo getSubscriberInfo(FindState findState) {
        if (findState.subscriberInfo != null && findState.subscriberInfo.getSuperSubscriberInfo() != null) {
            SubscriberInfo superclassInfo = findState.subscriberInfo.getSuperSubscriberInfo();
            if (findState.clazz == superclassInfo.getSubscriberClass()) {
                return superclassInfo;
            }
        }
        if (subscriberInfoIndexes != null) {
            for (SubscriberInfoIndex index : subscriberInfoIndexes) {
                SubscriberInfo info = index.getSubscriberInfo(findState.clazz);
                if (info != null) {
                    return info;
                }
            }
        }
        return null;
    }
```
如果此时findState如果本身有SubscriberInfo 缓存，则取出缓存，获取getSuperSubscriberInfo信息，如果和当前的类一直则返回。没有则获取下一个从构造函数传下来的subscriberInfoIndexes信息。这个信息就是在builder.addIndex加载进来的信息。

从demo上看index 类中的getSubscriberInfo方法
```
@Override
    public SubscriberInfo getSubscriberInfo(Class<?> subscriberClass) {
        SubscriberInfo info = SUBSCRIBER_INDEX.get(subscriberClass);
        if (info != null) {
            return info;
        } else {
            return null;
        }
    }
```

能看到的是，此时从中SUBSCRIBER_INDEX获取了缓存着的SimpleSubscriberInfo数据。



### 回到findUsingInfo
```
         if (findState.subscriberInfo != null) {
                SubscriberMethod[] array = findState.subscriberInfo.getSubscriberMethods();
                for (SubscriberMethod subscriberMethod : array) {
                    if (findState.checkAdd(subscriberMethod.method, subscriberMethod.eventType)) {
                        findState.subscriberMethods.add(subscriberMethod);
                    }
                }
            } else {
                findUsingReflectionInSingleClass(findState);
            }
            findState.moveToSuperclass();
```
此时回到findUsingInfo。我们看看循环体内部，此时我们能看到将会读取SimpleSubscriberInfo中的SubscriberMethod 数组，校验如果这个方法信息没有添加进去则添加到findState的缓存中。

此时如果subscriberInfo为空，说此时没有任何index数据,但是此时还存在着父类，则通过反射获取获取父类中的数据。知道为空。

因此我们可以知道，实际上在这个while循环中将会为每个类循环获取其方法，一直循环到父类为空为止。这样就能拿到每一个类继承链中所有加了@Subscriber注解的方法。

#### findUsingReflectionInSingleClass
接下来，能看到的是，如果findState.subscriberInfo为空将会走findUsingReflectionInSingleClass方法，或者ignoreGeneratedIndex标志位，忽略SubscriberInfoIndex 标志位，会走findUsingReflection。我们可以从名字里面明白。

实际上，这个步骤是忽略编译时注解生成的注解信息，直接反射获取@Subscriber注解的方法。

```
 private void findUsingReflectionInSingleClass(FindState findState) {
        Method[] methods;
        try {
            // This is faster than getMethods, especially when subscribers are fat classes like Activities
            methods = findState.clazz.getDeclaredMethods();
        } catch (Throwable th) {
            // Workaround for java.lang.NoClassDefFoundError, see https://github.com/greenrobot/EventBus/issues/149
            methods = findState.clazz.getMethods();
            findState.skipSuperClasses = true;
        }
        for (Method method : methods) {
            int modifiers = method.getModifiers();
            if ((modifiers & Modifier.PUBLIC) != 0 && (modifiers & MODIFIERS_IGNORE) == 0) {
                Class<?>[] parameterTypes = method.getParameterTypes();
                if (parameterTypes.length == 1) {
                    Subscribe subscribeAnnotation = method.getAnnotation(Subscribe.class);
                    if (subscribeAnnotation != null) {
                        Class<?> eventType = parameterTypes[0];
                        if (findState.checkAdd(method, eventType)) {
                            ThreadMode threadMode = subscribeAnnotation.threadMode();
                            findState.subscriberMethods.add(new SubscriberMethod(method, eventType, threadMode,
                                    subscribeAnnotation.priority(), subscribeAnnotation.sticky()));
                        }
                    }
                } else if (strictMethodVerification && method.isAnnotationPresent(Subscribe.class)) {
                    String methodName = method.getDeclaringClass().getName() + "." + method.getName();
                    throw new EventBusException("@Subscribe method " + methodName +
                            "must have exactly 1 parameter but has " + parameterTypes.length);
                }
            } else if (strictMethodVerification && method.isAnnotationPresent(Subscribe.class)) {
                String methodName = method.getDeclaringClass().getName() + "." + method.getName();
                throw new EventBusException(methodName +
                        " is a illegal @Subscribe method: must be public, non-static, and non-abstract");
            }
        }
    }
```

我们从反射中就能看到，EventBus扫描类中加了@Subscribe 的方法逻辑。每一次扫描只会通过Subscribe 扫描当前的类中声明的方法，其次方法必须是public标示，并且要方法参数为1个的时候，才符合EventBus的扫描规则。

每一次都会通过findstate中记录的方法池子，记录已经扫描过的方法，扫描过的方法将不再添加到findState.subscriberMethods这个方法存储List中。


最后将会把这些信息，通过subscriberMethodFinder.findSubscriberMethods返回到EventBus的中。

### 2.通过subscribe的方法，校验SubscriberMethod的合法性，最后添加到全局缓存数据结构中
```
synchronized (this) {
            for (SubscriberMethod subscriberMethod : subscriberMethods) {
                subscribe(subscriber, subscriberMethod);
            }
        }
```
在EventBus的register下半段中，解析List中的subscriberMethod 对象。通过subscribe保存下来。能看到的是，这个方法名字和Rxjava中的很像，我们也可以形象的称其为订阅所有的扫描到类。

#### subcribe
```
// Must be called in synchronized block
    private void subscribe(Object subscriber, SubscriberMethod subscriberMethod) {
        Class<?> eventType = subscriberMethod.eventType;
        Subscription newSubscription = new Subscription(subscriber, subscriberMethod);
        CopyOnWriteArrayList<Subscription> subscriptions = subscriptionsByEventType.get(eventType);
        if (subscriptions == null) {
            subscriptions = new CopyOnWriteArrayList<>();
            subscriptionsByEventType.put(eventType, subscriptions);
        } else {
            if (subscriptions.contains(newSubscription)) {
                throw new EventBusException("Subscriber " + subscriber.getClass() + " already registered to event "
                        + eventType);
            }
        }

        int size = subscriptions.size();
        for (int i = 0; i <= size; i++) {
            if (i == size || subscriberMethod.priority > subscriptions.get(i).subscriberMethod.priority) {
                subscriptions.add(i, newSubscription);
                break;
            }
        }

        List<Class<?>> subscribedEvents = typesBySubscriber.get(subscriber);
        if (subscribedEvents == null) {
            subscribedEvents = new ArrayList<>();
            typesBySubscriber.put(subscriber, subscribedEvents);
        }
        subscribedEvents.add(eventType);

        if (subscriberMethod.sticky) {
            if (eventInheritance) {
                // Existing sticky events of all subclasses of eventType have to be considered.
                // Note: Iterating over all events may be inefficient with lots of sticky events,
                // thus data structure should be changed to allow a more efficient lookup
                // (e.g. an additional map storing sub classes of super classes: Class -> List<Class>).
                Set<Map.Entry<Class<?>, Object>> entries = stickyEvents.entrySet();
                for (Map.Entry<Class<?>, Object> entry : entries) {
                    Class<?> candidateEventType = entry.getKey();
                    if (eventType.isAssignableFrom(candidateEventType)) {
                        Object stickyEvent = entry.getValue();
                        checkPostStickyEventToSubscription(newSubscription, stickyEvent);
                    }
                }
            } else {
                Object stickyEvent = stickyEvents.get(eventType);
                checkPostStickyEventToSubscription(newSubscription, stickyEvent);
            }
        }
    }
```

上述代码同样可以分为2步骤。

- 1.校验合法，保存在全局缓存subscriptionsByEventType以及typesBySubscriber
- 2.处理，黏着事件。

#### 保存在全局缓存
```
    private final Map<Class<?>, CopyOnWriteArrayList<Subscription>> subscriptionsByEventType;
    private final Map<Object, List<Class<?>>> typesBySubscriber;
    private final Map<Class<?>, Object> stickyEvents;
```

```
Class<?> eventType = subscriberMethod.eventType;
        Subscription newSubscription = new Subscription(subscriber, subscriberMethod);
        CopyOnWriteArrayList<Subscription> subscriptions = subscriptionsByEventType.get(eventType);
        if (subscriptions == null) {
            subscriptions = new CopyOnWriteArrayList<>();
            subscriptionsByEventType.put(eventType, subscriptions);
        } else {
            if (subscriptions.contains(newSubscription)) {
                throw new EventBusException("Subscriber " + subscriber.getClass() + " already registered to event "
                        + eventType);
            }
        }

        int size = subscriptions.size();
        for (int i = 0; i <= size; i++) {
            if (i == size || subscriberMethod.priority > subscriptions.get(i).subscriberMethod.priority) {
                subscriptions.add(i, newSubscription);
                break;
            }
        }

        List<Class<?>> subscribedEvents = typesBySubscriber.get(subscriber);
        if (subscribedEvents == null) {
            subscribedEvents = new ArrayList<>();
            typesBySubscriber.put(subscriber, subscribedEvents);
        }
        subscribedEvents.add(eventType);
```

我们能看到这里面存在三个全局缓存:
- 1.subscriptionsByEventType  以@Subscribe注解中对应方法的参数类型为key，把对象和方法信息保存到CopyOnWriteArrayList作为value。方便之后post去找该参数类型对应的类，也就是方便查找类中监听着什么事件。

- 2.typesBySubscriber  以subscriber（注册进来的类对应的实例）为key，以该类中所有方法中参数类型的List为value，方便通过实例反过来搜索，该类中包含所有的需要监听的事件类型是什么。
- 3.stickyEvents 保存着所有黏着事件。

值得注意的是，subscriptionsByEventType中的对象和方法信息。在全局会判断在这种需要的监听类型中，只能存在一种类实例和对应的方法参数。不能出现重复的。不然则会报错。为了避免出现register两次以上。


#### checkPostStickyEventToSubscription 管理黏着事件
```

        if (subscriberMethod.sticky) {
            if (eventInheritance) {
                // Existing sticky events of all subclasses of eventType have to be considered.
                // Note: Iterating over all events may be inefficient with lots of sticky events,
                // thus data structure should be changed to allow a more efficient lookup
                // (e.g. an additional map storing sub classes of super classes: Class -> List<Class>).
                Set<Map.Entry<Class<?>, Object>> entries = stickyEvents.entrySet();
                for (Map.Entry<Class<?>, Object> entry : entries) {
                    Class<?> candidateEventType = entry.getKey();
                    if (eventType.isAssignableFrom(candidateEventType)) {
                        Object stickyEvent = entry.getValue();
                        checkPostStickyEventToSubscription(newSubscription, stickyEvent);
                    }
                }
            } else {
                Object stickyEvent = stickyEvents.get(eventType);
                checkPostStickyEventToSubscription(newSubscription, stickyEvent);
            }
        }
```

eventInheritance 这个标志是用来判断黏着事件是否需要发送到父类。默认是false，不发送。我们先看看checkPostStickyEventToSubscription方法。
```
private void checkPostStickyEventToSubscription(Subscription newSubscription, Object stickyEvent) {
        if (stickyEvent != null) {
            // If the subscriber is trying to abort the event, it will fail (event is not tracked in posting state)
            // --> Strange corner case, which we don't take care of here.
            postToSubscription(newSubscription, stickyEvent, isMainThread());
        }
    }
```

实际上该方法的核心就是postToSubscription。这个方法就是EventBus,Post发送事件。我们可以知道，所谓的黏着事件是在每一次register的时候，发送一次那些通过postSticky保存在stickyEvents全局缓存中的事件。

## post EventBus事件发送
EventBus中post方法，才是这个事件分发库的核心思想。让我们聊聊其中的设计思想。

同样的，我们把发送看成4个步骤：
- 1.加入发送队列，逐一发送
- 2.检测发送事件的合法，以及发送事件的范围
- 3.从subscriptionsByEventType检索出要监听这种事件的，被观察者。
- 4.切换线程，发送信息到对应的接受方法中。

### 1.加入发送队列，逐一发送
```
 public void post(Object event) {
        PostingThreadState postingState = currentPostingThreadState.get();
        List<Object> eventQueue = postingState.eventQueue;
        eventQueue.add(event);

        if (!postingState.isPosting) {
            postingState.isMainThread = isMainThread();
            postingState.isPosting = true;
            if (postingState.canceled) {
                throw new EventBusException("Internal error. Abort state was not reset");
            }
            try {
                while (!eventQueue.isEmpty()) {
                    postSingleEvent(eventQueue.remove(0), postingState);
                }
            } finally {
                postingState.isPosting = false;
                postingState.isMainThread = false;
            }
        }
    }
```


实际上从post方法就能看到EventBus设计上的优秀。首先，我们能看到currentPostingThreadState这个对象。实际上，该对象是一个ThreadLocal，一个线程副本数据。
```
private final ThreadLocal<PostingThreadState> currentPostingThreadState = new ThreadLocal<PostingThreadState>() {
        @Override
        protected PostingThreadState initialValue() {
            return new PostingThreadState();
        }
    };
```

如果阅读过我2年前的文章就能知道，实际上这种方式是保护线程的安全之一。能够为当前设置线程设置一个副本数据，从而解决线程安全问题。在该类中存在必要的数据:
```
  final static class PostingThreadState {
        final List<Object> eventQueue = new ArrayList<>();
        boolean isPosting;
        boolean isMainThread;
        Subscription subscription;
        Object event;
        boolean canceled;
    }
```
其中eventQueue 是当前线程中的发送的队列。

回到post的逻辑，就能明白。此时每一次post都会添加到eventQueue 发送队列中。同时初始化当前postState的状态，确定当前的线程。最后再循环eventQueue队列中所有的事件调用postSingleEvent来进行发送。

### 2.postSingleEvent 检测发送事件的合法，以及发送事件的范围
```
 private void postSingleEvent(Object event, PostingThreadState postingState) throws Error {
        Class<?> eventClass = event.getClass();
        boolean subscriptionFound = false;
        if (eventInheritance) {
            List<Class<?>> eventTypes = lookupAllEventTypes(eventClass);
            int countTypes = eventTypes.size();
            for (int h = 0; h < countTypes; h++) {
                Class<?> clazz = eventTypes.get(h);
                subscriptionFound |= postSingleEventForEventType(event, postingState, clazz);
            }
        } else {
            subscriptionFound = postSingleEventForEventType(event, postingState, eventClass);
        }
        if (!subscriptionFound) {
            if (logNoSubscriberMessages) {
                logger.log(Level.FINE, "No subscribers registered for event " + eventClass);
            }
            if (sendNoSubscriberEvent && eventClass != NoSubscriberEvent.class &&
                    eventClass != SubscriberExceptionEvent.class) {
                post(new NoSubscriberEvent(this, event));
            }
        }
    }
```
对于这个流程，在此时可以看到eventInheritance会查找当前类中所有的范围，也可能父类，可能是接口中@Subscribe。否则直接postSingleEventForEventType方法进一步的发送事件，如果事件没找到对应的接受者，则发送一个NoSubscriberEvent，来告诉用户找不到接受事件的被观察者。

#### 3.从subscriptionsByEventType检索出要监听这种事件的被观察者
```
private boolean postSingleEventForEventType(Object event, PostingThreadState postingState, Class<?> eventClass) {
        CopyOnWriteArrayList<Subscription> subscriptions;
        synchronized (this) {
            subscriptions = subscriptionsByEventType.get(eventClass);
        }
        if (subscriptions != null && !subscriptions.isEmpty()) {
            for (Subscription subscription : subscriptions) {
                postingState.event = event;
                postingState.subscription = subscription;
                boolean aborted = false;
                try {
                    postToSubscription(subscription, event, postingState.isMainThread);
                    aborted = postingState.canceled;
                } finally {
                    postingState.event = null;
                    postingState.subscription = null;
                    postingState.canceled = false;
                }
                if (aborted) {
                    break;
                }
            }
            return true;
        }
        return false;
    }
```
从这里我们能看到本质上是通过发送的事件的类型来查找subscriptionsByEventType HashMap中对应类型的被观察者对象列表。值得注意的一点，因为HashMap没有线程安全，因此通过synchronized 进行了线程保护。

最后再postToSubscription进行发送工作区的切换以及发送事件的完成。


#### 4.切换线程，发送信息到对应的接受方法中
```
private void postToSubscription(Subscription subscription, Object event, boolean isMainThread) {
        switch (subscription.subscriberMethod.threadMode) {
            case POSTING:
                invokeSubscriber(subscription, event);
                break;
            case MAIN:
                if (isMainThread) {
                    invokeSubscriber(subscription, event);
                } else {
                    mainThreadPoster.enqueue(subscription, event);
                }
                break;
            case MAIN_ORDERED:
                if (mainThreadPoster != null) {
                    mainThreadPoster.enqueue(subscription, event);
                } else {
                    // temporary: technically not correct as poster not decoupled from subscriber
                    invokeSubscriber(subscription, event);
                }
                break;
            case BACKGROUND:
                if (isMainThread) {
                    backgroundPoster.enqueue(subscription, event);
                } else {
                    invokeSubscriber(subscription, event);
                }
                break;
            case ASYNC:
                asyncPoster.enqueue(subscription, event);
                break;
            default:
                throw new IllegalStateException("Unknown thread mode: " + subscription.subscriberMethod.threadMode);
        }
    }
```

实际上我们就能看到在 @Subscribe中设置的5种threadMode，在这个方法中分别作为5种情况处理。

- 1.POSTING  代表着什么线程发送，就在什么线程处理
- 2.MAIN 是最常用的，发送到主线程中处理
- 3.MAIN_ORDERED 不管在什么线程发送，都是先切换到主线程发送。除非主线程工作区没有设置，就发送到当前线程。
- 4.BACKGROUND 发送另一个线程后台中循环处理
- 5.ASYNC 每一次都从缓存线程池中，获取一个线程的处理。

我们先不看线程切换，我们看看在理想的情况，在主线程发送，在主线程接受。将会调用如下代码.
```
 void invokeSubscriber(Subscription subscription, Object event) {
        try {
            subscription.subscriberMethod.method.invoke(subscription.subscriber, event);
        } catch (InvocationTargetException e) {
            handleSubscriberException(subscription, event, e.getCause());
        } catch (IllegalAccessException e) {
            throw new IllegalStateException("Unexpected exception", e);
        }
    }
```

很简单吧。实际上就是通过反射，调用一次代码，把对应的类中方法反射调用，并且把事件传输到被观察者的接受方法中。


## EventBus 的线程切换
我们能看到在这里面的有一个关键的角色poster，根据上述类型分为3种poster。让我们看看这几种poster的UML图。
![EventBusPoster.png](/images/EventBusPoster.png)

我们能看到实际上EventBus的机制和Android的handler机制很相似。

我们比较一下Handler机制。

- 在Handler中Message作为消息的承载对象，同理在Poster中存在着PendingPost作为消息的承载对象。

- 在每一个Handler中都有自己的MessageQueue。同理在Poster中存在PendingPostQueue作为消息队列。

- 在Handler中存在着Looper作为驱动(因为有naitve的下层的管道会唤醒Looper)，而Poster中承载这种角色的就有不少不同，首先HandlerPost 中以Handler作为核心驱动，在BackgroundPoster和AsyncPoster中以ExecutorService最为驱动。

- 4.EventBus和Handler的定位就很相似。都是这个设计中的处理器。

通过这些比较，我们大致上可以猜测到EventBus的设计原理。
接下来，将会分别讲解一下这三个EventBus中Poster的原理，先来看看最常用的HandlerPoster。

### HandlerPoster
```
public class HandlerPoster extends Handler implements Poster {

    private final PendingPostQueue queue;
    private final int maxMillisInsideHandleMessage;
    private final EventBus eventBus;
    private boolean handlerActive;

    protected HandlerPoster(EventBus eventBus, Looper looper, int maxMillisInsideHandleMessage) {
        super(looper);
        this.eventBus = eventBus;
        this.maxMillisInsideHandleMessage = maxMillisInsideHandleMessage;
        queue = new PendingPostQueue();
    }

    public void enqueue(Subscription subscription, Object event) {
        PendingPost pendingPost = PendingPost.obtainPendingPost(subscription, event);
        synchronized (this) {
            queue.enqueue(pendingPost);
            if (!handlerActive) {
                handlerActive = true;
                if (!sendMessage(obtainMessage())) {
                    throw new EventBusException("Could not send handler message");
                }
            }
        }
    }

    @Override
    public void handleMessage(Message msg) {
        boolean rescheduled = false;
        try {
            long started = SystemClock.uptimeMillis();
            while (true) {
                PendingPost pendingPost = queue.poll();
                if (pendingPost == null) {
                    synchronized (this) {
                        // Check again, this time in synchronized
                        pendingPost = queue.poll();
                        if (pendingPost == null) {
                            handlerActive = false;
                            return;
                        }
                    }
                }
                eventBus.invokeSubscriber(pendingPost);
                long timeInMethod = SystemClock.uptimeMillis() - started;
                if (timeInMethod >= maxMillisInsideHandleMessage) {
                    if (!sendMessage(obtainMessage())) {
                        throw new EventBusException("Could not send handler message");
                    }
                    rescheduled = true;
                    return;
                }
            }
        } finally {
            handlerActive = rescheduled;
        }
    }
}
```

实际上这个类十分简单。每个Post在构造函数的时候都会新建一个PendingPostQueue。用来保存发送的事件，以及被观察者。
#### HandlerPoster.enqueue
顺着逻辑说一下，当我们调用下面方法时候，会把当前的事件实例以及被观察者(反射而的类名以及方法相关参数)放置到PendingPost中。看到这个obtain方法，我们应该能够下意识的反应过来，这是享元设计。
> mainThreadPoster.enqueue(subscription, event);

```
static PendingPost obtainPendingPost(Subscription subscription, Object event) {
        synchronized (pendingPostPool) {
            int size = pendingPostPool.size();
            if (size > 0) {
                PendingPost pendingPost = pendingPostPool.remove(size - 1);
                pendingPost.event = event;
                pendingPost.subscription = subscription;
                pendingPost.next = null;
                return pendingPost;
            }
        }
        return new PendingPost(event, subscription);
    }
```
能看到的是，所有的对象都会在pendingPostPool中管理，复用。

紧接着能看到把数据封装到pendingPost,最后将会enqueue到PendingPostQueue中。最后再调用sendMessage(obtainMessage())发送一个空的Message对象，驱动整个Poster的流程.

#### HandlerPoster.handleMessage
既然通过handler发送了数据，那么必定会会在handlemessage方法中接受.
```
 public void handleMessage(Message msg) {
        boolean rescheduled = false;
        try {
            long started = SystemClock.uptimeMillis();
            while (true) {
                PendingPost pendingPost = queue.poll();
                if (pendingPost == null) {
                    synchronized (this) {
                        pendingPost = queue.poll();
                        if (pendingPost == null) {
                            handlerActive = false;
                            return;
                        }
                    }
                }
                eventBus.invokeSubscriber(pendingPost);
                long timeInMethod = SystemClock.uptimeMillis() - started;
                if (timeInMethod >= maxMillisInsideHandleMessage) {
                    if (!sendMessage(obtainMessage())) {
                        throw new EventBusException("Could not send handler message");
                    }
                    rescheduled = true;
                    return;
                }
            }
        } finally {
            handlerActive = rescheduled;
        }
    }
```
我们此时就能发现，在这个方法中将会取出刚刚加进来的顶部事件，接着调用invokeSubscriber，反射对应的方法以及传入事件进去，就完成了整个流程。

值得注意的是，这里实际上是一个while循环，会把存入到PendingPostQueue一致循环到底部为止。还有一个通过rescheduled 来判断当前的handler是否在工作，正在工作则存入PendingPostQueue中，否则则直接sendMessage让handler处理事件。

在这里面我们能看到单例中的双重验证的方式来判断单例是否存在的方式，而这里也是用来判断当前pendingPost 是否为空。

### BackgroundPoster
```
final class BackgroundPoster implements Runnable, Poster {

    private final PendingPostQueue queue;
    private final EventBus eventBus;

    private volatile boolean executorRunning;

    BackgroundPoster(EventBus eventBus) {
        this.eventBus = eventBus;
        queue = new PendingPostQueue();
    }

    public void enqueue(Subscription subscription, Object event) {
        PendingPost pendingPost = PendingPost.obtainPendingPost(subscription, event);
        synchronized (this) {
            queue.enqueue(pendingPost);
            if (!executorRunning) {
                executorRunning = true;
                eventBus.getExecutorService().execute(this);
            }
        }
    }

    @Override
    public void run() {
        try {
            try {
                while (true) {
                    PendingPost pendingPost = queue.poll(1000);
                    if (pendingPost == null) {
                        synchronized (this) {
                            // Check again, this time in synchronized
                            pendingPost = queue.poll();
                            if (pendingPost == null) {
                                executorRunning = false;
                                return;
                            }
                        }
                    }
                    eventBus.invokeSubscriber(pendingPost);
                }
            } catch (InterruptedException e) {
                eventBus.getLogger().log(Level.WARNING, Thread.currentThread().getName() + " was interruppted", e);
            }
        } finally {
            executorRunning = false;
        }
    }
}
```

BackgroundPoster比想象中还要简单。按照上面的逻辑看下来，实际上就是获取一个Executors.newCachedThreadPool()缓存线程池。因为本身实现了runnable接口，因此可以看到，将会调用run的方法。

此时的逻辑和和handler很相似，在线程池没有循环处理完PendingPosterQueue的消息将会放到queue中不去执行，否则则继续执行消费PendingPosterQueue的消息。这样就能保证background，尽可能的只在一个后台线程处理。

### AsyncPoster
```
class AsyncPoster implements Runnable, Poster {

    private final PendingPostQueue queue;
    private final EventBus eventBus;

    AsyncPoster(EventBus eventBus) {
        this.eventBus = eventBus;
        queue = new PendingPostQueue();
    }

    public void enqueue(Subscription subscription, Object event) {
        PendingPost pendingPost = PendingPost.obtainPendingPost(subscription, event);
        queue.enqueue(pendingPost);
        eventBus.getExecutorService().execute(this);
    }

    @Override
    public void run() {
        PendingPost pendingPost = queue.poll();
        if(pendingPost == null) {
            throw new IllegalStateException("No pending post available");
        }
        eventBus.invokeSubscriber(pendingPost);
    }

}
```

该逻辑更加简单，没有任何的等待，只需要新的消息需要消费，就必定从线程池中获取一个线程去处理。


## PendingPostQueue 消费者生产者队列
实际上，我们是怎么保证在这个过程中，让post的消息有序的进行下去呢？这就和PendingPostQueue 的机制有关。这个队列实际上是一个消费者生产者队列。只要稍微熟悉线程设计的人都会明白这种经典的处理方式。

其核心，就是三句话，当消费者消费事件到了临界值，等待。当生产者生产到了临界值，等待。为了避免死锁，一般先会防止一个事件进去。

实际上这是一个最简单的消费者生产者队列，甚至还称不上完整的消费者生产者队列。
```
final class PendingPostQueue {
    private PendingPost head;
    private PendingPost tail;

    synchronized void enqueue(PendingPost pendingPost) {
        if (pendingPost == null) {
            throw new NullPointerException("null cannot be enqueued");
        }
        if (tail != null) {
            tail.next = pendingPost;
            tail = pendingPost;
        } else if (head == null) {
            head = tail = pendingPost;
        } else {
            throw new IllegalStateException("Head present, but no tail");
        }
        notifyAll();
    }

    synchronized PendingPost poll() {
        PendingPost pendingPost = head;
        if (head != null) {
            head = head.next;
            if (head == null) {
                tail = null;
            }
        }
        return pendingPost;
    }

    synchronized PendingPost poll(int maxMillisToWait) throws InterruptedException {
        if (head == null) {
            wait(maxMillisToWait);
        }
        return poll();
    }

}
```

能看到其设计和链表相似，每一次enqueue压入一个pendingPost ，会在当前尾部添加一个头部pendingPost。如果头部和尾部都为空则首尾都为当前的pendingPost ，就类似链表中的首尾指针相连。接着notifyAll唤起所有等待线程。

当poll的时候，如果头部为空，则会挂起线程，等待maxMillisToWait毫秒,等待enqueue生产新的pendingpost
,才获取pendingPost。

注意这种设计只会希望在有序的进行某种事务时候才使用。因此在BackgroundPoster中使用了poll(int maxMillisToWait) ，而AsyncPoster直接使用了poll()方法。

# 总结
至此，EventBus所有的要点都大部分解析了。总结一下，EventBus的核心思想是观察者设计模式，核心思路很简单，就是通过扫描类中加了注解的方法作为被观察者接收器，以及获取方法中参数类型作为这种接收器的接受什么类型事件。在post的时候，筛选出来，反射方法，调用存在全局的缓存方法信息。

当然对于EventBus过于解耦的问题，我还有一些其他的思考，详情可见：[FragmentEvent的合计初衷](https://github.com/yjy239/FragmentEvent/wiki/%E4%BB%8B%E7%BB%8D%E4%B8%8E%E5%88%9D%E8%A1%B7)




